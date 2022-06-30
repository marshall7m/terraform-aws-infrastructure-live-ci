import os
import sys
import logging
import git
import aurora_data_api
import re
import boto3
from pprint import pformat
import json
from typing import List
from collections import defaultdict
from common.utils import (
    send_task_status,
    subprocess_run,
    TerragruntException,
    ClientException,
)

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm")
lb = boto3.client("lambda")


class CreateStack:
    def get_new_providers(self, path: str, role_arn) -> List[str]:
        """
        Returns list of Terraform provider sources that are defined within the `path` that are not within the terraform state

        Arguments:
            path: Absolute path to a directory that contains atleast one Terragrunt *.hcl file
            role_arn: Role used for running terragrunt command
        """
        log.debug(f"Path: {path}")
        run = subprocess_run(
            f"terragrunt providers --terragrunt-working-dir {path} --terragrunt-iam-role {role_arn}"
        )

        cfg_providers = re.findall(
            r"(?<=─\sprovider\[).+(?=\])", run.stdout, re.MULTILINE
        )
        state_providers = re.findall(
            r"(?<=\s\sprovider\[).+(?=\])", run.stdout, re.MULTILINE
        )

        log.debug(f"Config providers:\n{cfg_providers}")
        log.debug(f"State providers:\n{state_providers}")

        return list(set(cfg_providers).difference(state_providers))

    def create_stack(self, path: str, role_arn: str) -> List[map]:
        """
        Creates a list of dictionaries consisting of a Terragrunt path that contains differences and the path's associated Terragrunt dependencies and new providers

        Arguments:
            path: Parent directory to search for differences within. When $GRAPH_DEPS is not set, terragrunt run-all plan
            will be used to search for differences which means the parent directory must contain a `terragrunt.hcl` file.
            role_arn: Role used for running terragrunt commands
        """

        graph_deps_run = subprocess_run(
            f"terragrunt graph-dependencies --terragrunt-working-dir {path} --terragrunt-iam-role {role_arn}"
        )

        # parses output of command to create a map of directories with a list of their directory dependencies
        graph_deps = defaultdict(list)
        for m in re.finditer(
            r'\t"(.+?)("\s;|"\s->\s")(.+(?=";)|$)', graph_deps_run.stdout, re.MULTILINE
        ):
            if m.group(3) != "":
                graph_deps[m.group(1)].append(m.group(3))
            else:
                graph_deps[m.group(1)]

        graph_deps = dict(graph_deps)
        log.debug(f"Graph Dependency mapping: \n{pformat(graph_deps)}")

        repo = git.Repo(search_parent_directories=True)
        # if set, use graph-dependencies map to determine target execution directories
        log.debug(f'$GRAPH_SCAN: {os.environ.get("GRAPH_SCAN", "")}')
        if os.environ.get("GRAPH_SCAN", False):
            log.info("Running Graph Scan")
            target_diff_paths = []
            # collects directories that contain new, modified and deleted .hcl/.tf files
            parent = repo.commit(os.environ["CODEBUILD_RESOLVED_SOURCE_VERSION"] + "^")
            log.debug(
                f'Getting git differences between commits: {parent.hexsha} and {os.environ["CODEBUILD_RESOLVED_SOURCE_VERSION"]}'
            )
            for diff in parent.diff(
                os.environ["CODEBUILD_RESOLVED_SOURCE_VERSION"],
                paths=[f"{path}/**.hcl", f"{path}/**.tf"],
            ):
                if diff.change_type in ["A", "M", "D"]:
                    target_diff_paths.append(
                        repo.working_dir + "/" + os.path.dirname(diff.a_path)
                    )
            target_diff_paths = list(set(target_diff_paths))

            log.debug(f"Git detected differences:\n{target_diff_paths}")
            diff_paths = []
            # recursively searches for the diff directories within the graph dependencies mapping to include chained dependencies
            while len(target_diff_paths) > 0:
                log.debug("Current Git diffs list:")
                log.debug(target_diff_paths)
                path = target_diff_paths.pop()
                for cfg_path, cfg_deps in graph_deps.items():
                    if cfg_path == path:
                        diff_paths.append(path)
                    if path in cfg_deps:
                        target_diff_paths.append(cfg_path)

            diff_paths = list(set(diff_paths))
        else:
            log.info("Running Plan Scan")
            # use the terraform exitcode for each directory found in the terragrunt run-all plan output to determine target execution directories
            # set check=False to prevent error raise since the -detailed-exitcode flags causes a return code of 2 if diff in tf plan
            run = subprocess_run(
                f"terragrunt run-all plan --terragrunt-working-dir {path} --terragrunt-iam-role {role_arn} --terragrunt-non-interactive -detailed-exitcode",
                check=False,
            )

            if run.returncode not in [0, 2]:
                log.error(f"Stderr: {run.stderr}")
                raise TerragruntException(
                    "Terragrunt run-all plan command failed -- Aborting CodeBuild run"
                )

            # selects directories that contains a exitcode of 2 meaning there is a difference in the terraform plan
            diff_paths = re.findall(
                r"(?<=exit\sstatus\s2\n\n\sprefix=\[).+?(?=\])", run.stderr, re.DOTALL
            )

        if len(diff_paths) == 0:
            log.debug("Detected no Terragrunt paths with difference")
            return []
        else:
            log.debug(f"Detected new/modified Terragrunt paths:\n{diff_paths}")

        stack = []
        for cfg_path, cfg_deps in graph_deps.items():
            if cfg_path in diff_paths:
                stack.append(
                    {
                        "cfg_path": os.path.relpath(cfg_path, repo.working_dir),
                        # only selects dependencies that contain differences
                        "cfg_deps": [
                            os.path.relpath(dep, repo.working_dir)
                            for dep in cfg_deps
                            if dep in diff_paths
                        ],
                        "new_providers": self.get_new_providers(cfg_path, role_arn),
                    }
                )
        return stack

    def update_executions_with_new_deploy_stack(self) -> None:
        """
        Iterates through every parent account-level directory and insert it's associated deployment stack within the metadb
        """
        with aurora_data_api.connect(
            aurora_cluster_arn=os.environ["METADB_CLUSTER_ARN"],
            secret_arn=os.environ["METADB_SECRET_ARN"],
            database=os.environ["METADB_NAME"],
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT account_path, plan_role_arn FROM account_dim ORDER BY account_name"
                )
                accounts = [{"path": r[0], "role": r[1]} for r in cur.fetchall()]

                log.debug(f"Accounts:\n{accounts}")

                if len(accounts) == 0:
                    log.fatal("No account paths are defined in account_dim")
                    sys.exit(1)

                try:
                    log.info("Getting account stacks")
                    for account in accounts:
                        log.info(f'Account path: {account["path"]}')
                        log.debug(f'Account plan role ARN: {account["role"]}')

                        if not os.path.isdir(account["path"]):
                            raise ClientException(
                                f'Account path does not exist within repo: {account["path"]}'
                            )

                        stack = self.create_stack(account["path"], account["role"])

                        log.debug(f"Stack:\n{stack}")

                        if len(stack) == 0:
                            log.debug("Stack is empty -- skipping")
                            continue

                        with open(
                            f"{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_deploy_stack.sql",
                            "r",
                        ) as f:
                            query = f.read().format(
                                pr_id=os.environ["CODEBUILD_WEBHOOK_TRIGGER"].split(
                                    "/"
                                )[1],
                                commit_id=os.environ[
                                    "CODEBUILD_RESOLVED_SOURCE_VERSION"
                                ],
                                account_path=account["path"],
                                base_ref=os.environ["CODEBUILD_WEBHOOK_BASE_REF"],
                                head_ref=os.environ["CODEBUILD_WEBHOOK_HEAD_REF"],
                            )
                        log.debug(f"Query:\n{query}")

                        # convert lists to comma-delimitted strings that will parsed to TEXT[] within query
                        for cfg in stack:
                            for k, v in cfg.items():
                                if type(v) == list:
                                    cfg.update({k: ",".join(v)})

                        cur.executemany(query, stack)
                except Exception as e:
                    log.info("Rolling back execution insertions")
                    conn.rollback()
                    raise e
            return None

    def main(self) -> None:
        """
        When a PR that contains Terragrunt and/or Terraform changes is merged within the base branch, each of those new/modified Terragrunt directories will have an associated
        deployment record inserted into the metadb. After all records are inserted, a downstream AWS Lambda function will choose which of those records to run through the deployment flow.
        """
        log.info("Locking merge action within target branch")
        ssm.put_parameter(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value=os.environ["CODEBUILD_WEBHOOK_TRIGGER"].split("/")[1],
            Type="String",
            Overwrite=True,
        )
        try:
            try:
                log.info("Creating deployment execution records")
                self.update_executions_with_new_deploy_stack()
            except Exception as e:
                log.error(e, exc_info=True)
                log.info("Unlocking merge action within target branch")
                ssm.put_parameter(
                    Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
                    Value="none",
                    Type="String",
                    Overwrite=True,
                )
                raise e

            log.info(
                f'Invoking Lambda Function: {os.environ["TRIGGER_SF_FUNCTION_NAME"]}'
            )
            lb.invoke(
                FunctionName=os.environ["TRIGGER_SF_FUNCTION_NAME"],
                InvocationType="Event",
                Payload=json.dumps(
                    {"pr_id": os.environ["CODEBUILD_WEBHOOK_TRIGGER"].split("/")[1]}
                ),
            )
            state = "success"
        except Exception as e:
            log.error(e, exc_info=True)
            state = "failure"

        send_task_status(state, "Create Deploy Stack")

    def cleanup(self):

        log.debug("Closing metadb cursor")
        self.cur.close()

        log.debug("Closing metadb connection")
        self.conn.close()


if __name__ == "__main__":
    run = CreateStack()
    run.main()
