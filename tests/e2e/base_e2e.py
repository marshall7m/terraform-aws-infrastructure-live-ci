import os
import logging
import json
import time
from datetime import datetime
import timeout_decorator
from pprint import pformat
import uuid

import pytest
import aurora_data_api
import boto3
import requests
import github

from tests.helpers.utils import (
    get_finished_commit_status,
    get_execution_arn,
    get_sf_state_event,
    ses_approval,
    push,
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

    @pytest.fixture(scope="class")
    def repo(self, mut_output):
        return github.Github(os.environ["GITHUB_TOKEN"], retry=3).get_repo(
            mut_output["repo_full_name"]
        )

    @pytest.fixture(scope="class")
    def pr(self, repo, mut_output, request):
        """
        Creates and destroys GitHub PR.
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

    @timeout_decorator.timeout(30)
    @pytest.fixture(scope="class")
    def merge_lock_pr_status(self, repo, mut_output, pr):
        """Gets merge lock commit status"""

        return get_finished_commit_status(
            mut_output["merge_lock_status_check_name"], repo, pr["head_commit_id"]
        )

    @timeout_decorator.timeout(300)
    @pytest.fixture(scope="class")
    def pr_plan_pending_statuses(self, request, mut_output, pr, repo):
        """Assert PR plan tasks initial commit statuses were created"""

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
        statuses = []
        while len(statuses) != expected_count:
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            statuses = [
                status
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context != mut_output["merge_lock_status_check_name"]
            ]

        return statuses

    @timeout_decorator.timeout(300)
    @pytest.fixture(scope="class")
    def pr_plan_finished_statuses(self, pr_plan_pending_statuses, mut_output, pr, repo):
        """Assert PR plan tasks commit statuses were updated"""

        log.info("Waiting for all PR plan commit statuses to be updated")
        wait = 15
        statuses = []
        while len(statuses) != len(pr_plan_pending_statuses):
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            statuses = [
                status
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context != mut_output["merge_lock_status_check_name"]
                and status.state != "pending"
            ]

            log.debug(f"Finished count: {len(statuses)}")

        return statuses

    @timeout_decorator.timeout(30)
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

    @timeout_decorator.timeout(600)
    @pytest.fixture(scope="class")
    def create_deploy_stack_task_status(self, request, repo, mut_output, pr, merge_pr):
        """Assert create deploy stack status matches it's expected status"""
        return get_finished_commit_status(
            mut_output["create_deploy_stack_status_check_name"],
            repo,
            pr["head_commit_id"],
        )

    @timeout_decorator.timeout(
        300,
        exception_message="Expected atleast one untested execution to have a status of ('running', 'aborted', 'failed')",
    )
    @pytest.fixture(scope="class")
    def record(
        self, request, mut_output, pr, create_deploy_stack_task_status, target_execution
    ):
        """Queries metadb until the target execution record exists"""
        log.debug(f"Already tested execution IDs:\n{request.cls.tested_execution_ids}")

        results = None
        while not results:
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

        record = {}
        row = [value for value in results]
        for i, description in enumerate(cur.description):
            record[description.name] = row[i]

        log.debug(f"Target Execution Record:\n{pformat(record)}")

        return record

    @pytest.fixture(scope="class")
    def action(self, request, record):

        if record["is_rollback"]:
            return request.cls.case["executions"][record["cfg_path"]]["actions"][
                "rollback_providers"
            ]
        else:
            return (
                request.cls.case["executions"][record["cfg_path"]]
                .get("actions", {})
                .get("apply", None)
            )

    @pytest.fixture(scope="class")
    def execution_arn(mut_output, record):
        return get_execution_arn(
            mut_output["state_machine_arn"], record["execution_id"]
        )

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.fixture(scope="class")
    def terra_run_plan_status(self, request, mut_output, record, execution_arn):
        return get_sf_state_event(execution_arn, "Plan", "stateExitedEventDetails")

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.fixture(scope="class")
    def approval_request(self, execution_arn, terra_run_plan_status):
        status_code = None
        while not status_code:
            time.sleep(10)

            events = sf.get_execution_history(
                executionArn=execution_arn, includeExecutionData=True
            )["events"]

            for event in events:
                if (
                    event.get("taskSubmittedEventDetails", {}).get("resource")
                    == "publish.waitForTaskToken"
                ):
                    out = json.loads(event["taskSubmittedEventDetails"]["output"])
                    return out["SdkHttpMetadata"]

    @pytest.fixture(scope="class")
    def ses_approval_response(self, mut_output, action, approval_request):
        res = ses_approval(
            os.environ.get("APPROVAL_RECIPIENT_EMAIL"),
            os.environ.get("APPROVAL_RECIPIENT_PASSWORD"),
            os.environ.get("APPROVAL_REQUEST_SENDER_EMAIL"),
            mut_output["ses_approval_subject_template"],
            action,
        )

        return res

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.fixture(scope="class")
    def terra_run_apply_status(self, ses_approval_response, execution_arn):
        return get_sf_state_event(execution_arn, "Apply", "stateExitedEventDetails")

    @pytest.fixture(scope="class")
    def finished_sf_execution(self, terra_run_apply_status, execution_arn):
        """Assert Step Function execution succeeded"""
        log.info("Waiting for execution to finish")
        execution_status = None
        while execution_status not in ["SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"]:
            time.sleep(5)
            response = sf.describe_execution(executionArn=execution_arn)
            execution_status = response["status"]
            log.debug(f"Execution status: {execution_status}")

        return response
