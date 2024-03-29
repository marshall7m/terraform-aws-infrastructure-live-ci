import os
import sys
import logging
import re
import json
from typing import List
from collections import defaultdict
import fnmatch

import github
import aurora_data_api
import boto3

sys.path.append(os.path.dirname(__file__) + "/..")
from common.utils import (
    subprocess_run,
    TerragruntException,
    ClientException,
    get_task_log_url,
)

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
stream.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
log.addHandler(stream)
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))
lb = boto3.client("lambda", endpoint_url=os.environ.get("LAMBDA_ENDPOINT_URL"))
rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)


class CreateStack:
    def get_new_providers(self, path: str, role_arn: str) -> List[str]:
        """
        Returns list of Terraform provider sources that are defined within the
        `path` that are not within the Terraform state

        Arguments:
            path: Absolute path to a directory that contains atleast one Terragrunt *.hcl file
            role_arn: Role used for running Terragrunt command
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

    def get_graph_deps(self, path: str, role_arn: str) -> dict:
        """
        Returns a Python dictionary version of the `terragrunt graph-dependencies` command

        Arguments:
            path: Absolute path to a directory to run the Terragrunt command from
            role_arn: Role used for running Terragrunt command
        """
        graph_deps_run = subprocess_run(
            f"terragrunt graph-dependencies --terragrunt-working-dir {path} --terragrunt-iam-role {role_arn}"
        )

        # parses output of command to create a map of directories with a list of their directory dependencies
        # if directory has no dependency, map value default's to list
        graph_deps = defaultdict(list)
        for m in re.finditer(
            r'\t"(.+?)("\s;|"\s->\s")(.+(?=";)|$)', graph_deps_run.stdout, re.MULTILINE
        ):
            cfg = os.path.relpath(m.group(1), os.environ["SOURCE_REPO_PATH"])
            dep = m.group(3)
            if dep != "":
                graph_deps[cfg].append(
                    os.path.relpath(dep, os.environ["SOURCE_REPO_PATH"])
                )
            else:
                # initialize map key with emtpy list if dependency value is none
                graph_deps[cfg]

        return dict(graph_deps)

    def get_github_diff_paths(self, graph_deps: dict, path: str) -> List[str]:
        """
        Returns unique list of GitHub diff directories and the directories that
        are dependent on them. Function uses the graph-dependencies dictionary
        to find the directories that are dependent on the GitHub diff directories.

        Arguments:
            graph_deps: Terragrunt graph-dependencies Python version dictionary
            path: Parent directory to search for differences within
        """

        repo = github.Github(os.environ["GITHUB_TOKEN"], retry=3).get_repo(
            os.environ["REPO_FULL_NAME"]
        )

        log.info("Running Graph Scan")
        target_diff_paths = []

        log.debug(
            f"Getting git differences between commits: {os.environ['BASE_COMMIT_ID']} and {os.environ['COMMIT_ID']}"
        )
        for diff in repo.compare(
            os.environ["BASE_COMMIT_ID"], os.environ["COMMIT_ID"]
        ).files:
            # collects directories that contain new, modified and removed .hcl/.tf files
            if diff.status in ["added", "modified", "removed"]:
                if fnmatch.fnmatch(diff.filename, f"{path}/**.hcl") or fnmatch.fnmatch(
                    diff.filename, f"{path}/**.tf"
                ):
                    target_diff_paths.append(os.path.dirname(diff.filename))
        target_diff_paths = list(set(target_diff_paths))

        log.debug(f"Detected differences:\n{target_diff_paths}")
        diff_paths = []
        # recursively searches for the diff directories within the graph
        # dependencies mapping to include chained dependencies
        while len(target_diff_paths) > 0:
            log.debug(f"Current diffs list:\n{target_diff_paths}")
            path = target_diff_paths.pop()
            for cfg_path, cfg_deps in graph_deps.items():
                if cfg_path == path:
                    diff_paths.append(path)
                if path in cfg_deps:
                    target_diff_paths.append(cfg_path)

        return list(set(diff_paths))

    def get_plan_diff_paths(self, path, role_arn):
        """
        Returns unique list of Terragrunt directories that contain a difference
        in their respective Terraform state file.

        Arguments:
            path: Parent directory to search for differences within
            role_arn: Role used for running Terragrunt command
        """
        log.info("Running Plan Scan")
        # use the terraform exitcode for each directory found in the terragrunt
        # run-all plan output to determine what directories to collect

        # set check=False to prevent raising subprocess.CalledProcessError
        # since the -detailed-exitcode flags causes a return code of 2 if diff
        # in Terraform plan
        run = subprocess_run(
            f"terragrunt run-all plan --terragrunt-working-dir {path} --terragrunt-iam-role {role_arn} --terragrunt-non-interactive -detailed-exitcode",
            check=False,
        )

        if run.returncode not in [0, 2]:
            log.error(f"Stderr: {run.stderr}")
            raise TerragruntException(
                "Terragrunt run-all plan command failed -- Aborting task"
            )

        # selects directories that contains a exitcode of 2 meaning there is a
        # difference in the terraform plan
        return [
            os.path.relpath(p, os.environ["SOURCE_REPO_PATH"])
            for p in re.findall(
                r"(?<=exit\sstatus\s2\n\n\sprefix=\[).+?(?=\])", run.stderr, re.DOTALL
            )
        ]

    def create_stack(self, path: str, role_arn: str) -> List[map]:
        """
        Creates a list of dictionaries consisting of keys representing
        Terragrunt paths that contain differences in their respective
        Terraform tfstate file and values that contain the path's associated
        Terragrunt dependencies and new providers

        Arguments:
            path: Parent directory to search for differences within. When
                SCAN_TYPE is `plan`, terragrunt run-all plan will be used
                to search for differences which means the parent directory must
                contain a `terragrunt.hcl` file.
            role_arn: AWS account role used for running Terragrunt commands
        """

        if not os.path.isdir(path):
            raise ClientException(f"Account path does not exist within repo: {path}")

        graph_deps = self.get_graph_deps(path, role_arn)
        log.debug(f"Graph Dependency mapping: \n{json.dumps(graph_deps, indent=4)}")

        log.debug(f'Scan type: {os.environ["SCAN_TYPE"]}')

        if os.environ["SCAN_TYPE"] == "graph":
            diff_paths = self.get_github_diff_paths(graph_deps, path)
        elif os.environ["SCAN_TYPE"] == "plan":
            diff_paths = self.get_plan_diff_paths(path, role_arn)
        else:
            raise ClientException(f"Scan type is invalid: {os.environ['SCAN_TYPE']}")

        if len(diff_paths) == 0:
            log.debug("Detected no Terragrunt paths with differences")
            return []
        else:
            log.debug(f"Detected new/modified Terragrunt paths:\n{diff_paths}")

        stack = []
        for cfg_path, cfg_deps in graph_deps.items():
            if cfg_path in diff_paths:
                stack.append(
                    {
                        "cfg_path": cfg_path,
                        # only selects dependencies that contain differences
                        "cfg_deps": [dep for dep in cfg_deps if dep in diff_paths],
                        "new_providers": self.get_new_providers(cfg_path, role_arn),
                    }
                )
        return stack

    def update_executions_with_new_deploy_stack(self) -> None:
        """
        Iterates through every parent account-level directory and insert it's
        associated deployment stack within the metadb
        """
        with aurora_data_api.connect(
            aurora_cluster_arn=os.environ["AURORA_CLUSTER_ARN"],
            secret_arn=os.environ["AURORA_SECRET_ARN"],
            database=os.environ["METADB_NAME"],
            rds_data_client=rds_data_client,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                SELECT
                    account_name,
                    account_path,
                    account_deps::VARCHAR,
                    min_approval_count,
                    min_rejection_count,
                    voters::VARCHAR,
                    plan_role_arn,
                    apply_role_arn
                FROM account_dim
                ORDER BY account_name
                """
                )
                cols = [desc[0] for desc in cur.description]
                res = cur.fetchall()
                log.debug(f"Raw accounts records:\n{json.dumps(res, indent=4)}")
                accounts = []
                for account in res:
                    record = dict(zip(cols, account))
                    record["account_deps"] = (
                        record["account_deps"]
                        .removeprefix("{")
                        .removesuffix("}")
                        .split(",")
                    )
                    record["voters"] = (
                        record["voters"].removeprefix("{").removesuffix("}").split(",")
                    )
                    accounts.append(record)
                log.debug(f"Accounts:\n{json.dumps(accounts, indent=4)}")

                if len(accounts) == 0:
                    Exception("No account paths are defined in account_dim")

                try:
                    log.info("Getting account stacks")
                    for account in accounts:
                        log.info(f'Account path: {account["account_path"]}')
                        log.info(f'Account plan role ARN: {account["plan_role_arn"]}')

                        stack = self.create_stack(
                            account["account_path"], account["plan_role_arn"]
                        )

                        log.debug(f"Stack:\n{stack}")

                        if len(stack) == 0:
                            log.debug("Stack is empty -- skipping")
                            continue

                        # convert lists to comma-delimitted strings that will
                        # parsed to TEXT[] within query
                        stack_values = []
                        for cfg in stack:
                            stack_values.append(
                                str(
                                    tuple(
                                        [
                                            v if type(v) != list else ",".join(v)
                                            for v in cfg.values()
                                        ]
                                    )
                                )
                            )
                        stack_values = ",".join(stack_values)
                        with open(
                            f"{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_deploy_stack.sql",
                            "r",
                        ) as f:
                            query = f.read().format(
                                pr_id=os.environ["PR_ID"],
                                commit_id=os.environ["COMMIT_ID"],
                                base_ref=os.environ["BASE_REF"],
                                head_ref=os.environ["HEAD_REF"],
                                account_name=account["account_name"],
                                account_path=account["account_path"],
                                account_deps=",".join(account["account_deps"]),
                                min_approval_count=account["min_approval_count"],
                                min_rejection_count=account["min_rejection_count"],
                                voters=",".join(account["voters"]),
                                plan_role_arn=account["plan_role_arn"],
                                apply_role_arn=account["apply_role_arn"],
                                stack=stack_values,
                            )
                        log.debug(f"Query:\n{query}")

                        cur.execute(query)
                except Exception as e:
                    log.info("Rolling back execution insertions")
                    conn.rollback()
                    raise e
            return None

    def main(self) -> None:
        """
        When a PR that contains Terragrunt and/or Terraform changes is merged
        within the base branch, each of those new/modified Terragrunt
        directories will have an associated deployment record inserted into the
        metadb. After all records are inserted, a downstream AWS Lambda
        Function will choose which of those records to run through the
        AWS Step Function deployment flow.
        """
        log.info("Locking merge action within target branch")
        ssm.put_parameter(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value=os.environ["PR_ID"],
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
                # raise after sending failed commit status
                raise e

            log.info(
                f'Invoking Lambda Function: {os.environ["TRIGGER_SF_FUNCTION_NAME"]}'
            )
            lb.invoke(
                FunctionName=os.environ["TRIGGER_SF_FUNCTION_NAME"],
                InvocationType="Event",
                Payload=json.dumps({"pr_id": os.environ["PR_ID"]}),
            )
            state = "success"
        except Exception as e:
            log.error(e, exc_info=True)
            state = "failure"

        commit_status_config = json.loads(os.environ["COMMIT_STATUS_CONFIG"])
        log.debug(
            f"Commit status config:\n{json.dumps(commit_status_config, indent=4)}"
        )
        if commit_status_config[os.environ["STATUS_CHECK_NAME"]]:
            commit = (
                github.Github(os.environ["GITHUB_TOKEN"], retry=3)
                .get_repo(os.environ["REPO_FULL_NAME"])
                .get_commit(os.environ["COMMIT_ID"])
            )

            log.info("Sending commit status")
            commit.create_status(
                state=state,
                context=os.environ["STATUS_CHECK_NAME"],
                target_url=get_task_log_url(),
            )


if __name__ == "__main__":
    run = CreateStack()
    run.main()
