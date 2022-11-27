import os
import logging
import json
import time
from pprint import pformat
import uuid

import pytest
import aurora_data_api
import boto3
import github

from tests.helpers.utils import (
    get_finished_commit_status,
    get_execution_arn,
    ses_approval,
    push,
    get_finished_sf_execution,
)

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ecs = boto3.client("ecs")
sf = boto3.client("stepfunctions")


class E2E:
    """
    Fixtures that interact with the CI/CD pipeline and/or retrieves data
    associated with the pipeline execution. Fixture dependencies reflect the order
    of the CI/CD workflow.
    """

    tested_execution_ids = []

    @pytest.fixture(scope="class")
    def repo(self, mut_output):
        return github.Github(os.environ["GITHUB_TOKEN"], retry=3).get_repo(
            mut_output["repo_full_name"]
        )

    @pytest.fixture(scope="class")
    def pr(self, repo, mut_output, request):
        """
        Manages lifecycle of GitHub PR associated with the test case.
        Current implementation creates all PR changes within one commit.
        """
        base_commit_id = repo.get_branch(mut_output["base_branch"]).commit.sha
        for dir, cfg in request.cls.case["executions"].items():
            if "pr_files_content" in cfg:
                changes = {
                    os.path.join(dir, str(uuid.uuid4()) + ".tf"): content
                    for content in cfg["pr_files_content"]
                }
                head_commit_id = push(repo, request.cls.case["head_ref"], changes)

        log.info("Creating PR")
        pr = repo.create_pull(
            title=request.cls.case.get("title", f"test-{request.cls.case['head_ref']}"),
            body=request.cls.case.get("body", "Test PR"),
            base=mut_output["base_branch"],
            head=request.cls.case["head_ref"],
        )

        yield {
            "full_name": repo.full_name,
            "number": pr.number,
            "base_commit_id": base_commit_id,
            "head_commit_id": head_commit_id,
            "base_ref": pr.base.ref,
            "head_ref": pr.head.ref,
        }

        log.info(f"Removing PR head ref branch: {request.cls.case['head_ref']}")
        repo.get_git_ref(f"heads/{request.cls.case['head_ref']}").delete()

        log.info(f"Closing PR: #{pr.number}")
        try:
            pr.edit(state="closed")
        except Exception:
            log.info("PR is merged or already closed")

    @pytest.fixture(scope="class")
    def pr_plan_pending_statuses(self, request, mut_output, pr, repo):
        """Returns list of PR plan tasks' initial commit statuses"""
        log.info("Waiting for all PR plan commit statuses to be created")
        expected_count = len(
            [
                1
                for cfg in request.cls.case["executions"].values()
                if "pr_files_content" in cfg
            ]
        )
        log.debug(f"Expected count: {expected_count}")
        wait = 10
        attempts = 0
        max_attempts = 12
        statuses = []
        while len(statuses) != expected_count:
            if attempts == max_attempts:
                pytest.fail(
                    "Max attempt reached -- Lambda Function might have failed beforehand"
                )
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            statuses = [
                status
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context != mut_output["merge_lock_status_check_name"]
            ]

            attempts += 1

        return statuses

    @pytest.fixture(scope="class")
    def pr_plan_finished_statuses(self, pr_plan_pending_statuses, mut_output, pr, repo):
        """Returns list of PR plan tasks' finished commit statuses"""
        log.info("Waiting for all PR plan commit statuses to be updated")
        wait = 15
        attempts = 0
        max_attempts = 12
        statuses = []
        while len(statuses) != len(pr_plan_pending_statuses):
            if attempts == max_attempts:
                pytest.fail(
                    "Max attempt reached -- ECS task might have failed beforehand"
                )
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            statuses = [
                status
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context != mut_output["merge_lock_status_check_name"]
                and status.state != "pending"
            ]

            log.debug(f"Finished count: {len(statuses)}")
            attempts += 1

        return statuses

    @pytest.fixture(scope="class")
    def merge_pr(self, pr_plan_finished_statuses, mut_output, pr, repo, git_repo):
        """Ensure that the PR merges without error"""

        log.info(f"Merging PR: #{pr['number']}")
        try:
            commit = repo.merge(pr["base_ref"], pr["head_ref"])
        except Exception as e:
            branch = repo.get_branch(branch=mut_output["base_branch"])
            log.debug(
                f"Branch protection enforced for admins: {branch.get_protection().enforce_admins}"
            )
            log.debug(
                f"Status Checks Required: {branch.get_required_status_checks().contexts}"
            )

            merge_lock_status = {
                status.context: status.state
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context == mut_output["merge_lock_status_check_name"]
            }
            log.debug(f"Merge Lock status: {merge_lock_status}")

            log.error(e, exc_info=True)
            raise e

        yield commit

        log.info(f'Removing PR changes from base branch: {mut_output["base_branch"]}')

        log.debug("Pulling remote changes")
        git_repo.git.reset("--hard")
        git_repo.git.pull()

        log.debug(
            "Removing admin enforcement from branch protection to allow revert pushes to trunk branch"
        )
        branch = repo.get_branch(branch=mut_output["base_branch"])
        branch.remove_admin_enforcement()

        log.debug("Removing required status checks")
        status_checks = branch.get_required_status_checks().contexts
        branch.edit_required_status_checks(contexts=[])
        current_status_checks = status_checks
        while len(current_status_checks) > 0:
            time.sleep(3)
            current_status_checks = branch.get_required_status_checks().contexts

        log.debug("Reverting all changes from testing PRs")
        try:
            log.debug(f"Merge Commit ID: {commit.sha}")

            git_repo.git.revert("-m", "1", "--no-commit", str(commit.sha))
            git_repo.git.commit(
                "-m",
                f"Revert changes from PR: {pr['head_ref']} within fixture teardown",
            )
            git_repo.git.push("origin", "--force")
        except Exception as e:
            raise e
        finally:
            log.debug("Adding admin enforcement back")
            branch.set_admin_enforcement()

            log.debug("Adding required status checks back")
            branch.edit_required_status_checks(contexts=status_checks)

    @pytest.fixture(scope="class")
    def create_deploy_stack_task_status(self, request, repo, mut_output, pr, merge_pr):
        """Returns create deploy stack finished commit status"""
        return get_finished_commit_status(
            mut_output["create_deploy_stack_status_check_name"],
            repo,
            pr["head_commit_id"],
            wait=10,
            max_attempts=10,
        )

    @pytest.fixture(scope="class")
    def record(
        self, request, mut_output, pr, create_deploy_stack_task_status, target_execution
    ):
        """Queries metadb until the target execution record exists"""
        log.debug(f"Already tested execution IDs:\n{request.cls.tested_execution_ids}")

        log.info("Getting next target execution record")
        max_attempts = 3
        attempt = 0
        results = None
        while not results:
            if attempt == max_attempts:
                pytest.fail("Max attempts reached -- record is not found")
            time.sleep(10)
            with aurora_data_api.connect(
                aurora_cluster_arn=mut_output["metadb_arn"],
                secret_arn=mut_output["metadb_secret_manager_master_arn"],
                database=mut_output["metadb_name"],
            ) as conn:
                with conn.cursor() as cur:

                    cur.execute(
                        f"""
                        SELECT *
                        FROM {mut_output["metadb_schema"]}.executions
                        WHERE commit_id = '{pr["head_commit_id"]}'
                        AND "status" IN ('running', 'aborted', 'failed')
                        AND NOT (execution_id = ANY (ARRAY{request.cls.tested_execution_ids}::TEXT[]))
                        LIMIT 1
                    """
                    )
                    results = cur.fetchone()
            attempt += 1

        record = {}
        row = [value for value in results]
        for i, description in enumerate(cur.description):
            record[description.name] = row[i]

        log.debug(f"Target Execution Record:\n{pformat(record)}")

        # ensures other parametrized record fixtures don't use this record
        request.cls.tested_execution_ids.append(record["execution_id"])

        return record

    @pytest.fixture(scope="class")
    def ses_approval_responses(self, request, mut_output, record) -> dict:
        """Returns approval response Lambda Function's response to voter's email client"""
        if record["status"] in ["failed", "aborted"]:
            pytest.skip(f"Execution approval action is set to {record['status']}")

        vote_config = request.cls.case["executions"][record["cfg_path"]]
        if record["is_rollback"]:
            votes = vote_config.get("rollback_votes", {}).get("email")
        else:
            votes = vote_config.get("deploy_votes", {}).get("email")
        if not votes:
            pytest.fail("Approval action is not set for record")

        responses = {}
        for address, action in votes.items():
            log.debug(f"Sending vote for address: {address}")
            log.debug(f"Action: {action}")
            res = ses_approval(
                username=address,
                password=os.environ.get("APPROVAL_RECIPIENT_PASSWORD"),
                msg_from=os.environ.get("APPROVAL_REQUEST_SENDER_EMAIL"),
                msg_subject=mut_output["ses_approval_subject_template"].replace(
                    "{{execution_name}}", record["execution_id"]
                ),
                action=action.capitalize(),
                mailboxes=["INBOX", "[Gmail]/Spam"],
                max_attempts=10,
            )

            responses[address] = res

        return responses

    @pytest.fixture(scope="class")
    def finished_sf_execution(self, mut_output, record, ses_approval_responses):
        """Returns Step Function execution finished status"""
        log.info("Waiting for execution to finish")
        arn = get_execution_arn(mut_output["state_machine_arn"], record["execution_id"])
        res = get_finished_sf_execution(arn, wait=10, max_attempts=100)
        log.debug(f"Finished Step Function describe response:\n{pformat(res)}")

        return res
