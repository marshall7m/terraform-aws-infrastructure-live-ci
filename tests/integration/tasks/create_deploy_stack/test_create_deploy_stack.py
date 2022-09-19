import os
import pytest
import logging
from tests.helpers.utils import dummy_tf_output
import boto3
import github
import uuid
import aurora_data_api
from tests.integration.tasks.utils import run_task


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)
rds_data = boto3.client("rds-data", endpoint_url=os.environ["METADB_ENDPOINT_URL"])


def get_commit_cfg_paths(commit_id, mut_output):
    with aurora_data_api.connect(
        aurora_cluster_arn=mut_output["metadb_arn"],
        secret_arn=mut_output["metadb_secret_manager_master_arn"],
        database=mut_output["metadb_name"],
        rds_data_client=rds_data,
    ) as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"""
            SELECT array_agg(cfg_path::TEXT)
            FROM {mut_output["metadb_schema"]}.executions
            WHERE commit_id = '{commit_id}'
            """
            )
            results = cur.fetchone()[0]

    return [] if results is None else [id for id in results]


@pytest.fixture
def send_commit_status(push_changes, mut_output):
    commit = (
        github.Github(os.environ["GITHUB_TOKEN"], retry=3)
        .get_repo(mut_output["repo_full_name"])
        .get_commit(push_changes["commit_id"])
    )

    log.info("Sending commit status")
    commit.create_status(
        state="pending",
        context=mut_output["create_deploy_stack_status_check_name"],
        target_url="http://localhost:8080",
    )


@pytest.mark.usefixtures("truncate_executions", "send_commit_status", "terra_setup")
class TestCreateDeployStack:
    @pytest.mark.parametrize(
        "push_changes,expected_cfg_paths",
        [
            pytest.param(
                {
                    f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output()
                },
                ["directory_dependency/shared-services-account/us-west-2/env-one/doo"],
                id="one_node",
            )
        ],
        indirect=["push_changes"],
    )
    def test_successful_execution(self, expected_cfg_paths, mut_output, push_changes):
        """
        Test ensures that the proper IAM permissions for the task role are in place, execution runs
        without any failures, expected metadb execution records were created, and expected commit status is sent.
        """
        run_task(
            mut_output=mut_output,
            task_def_arn=mut_output["ecs_create_deploy_stack_definition_arn"],
            task_env_vars={
                "BASE_REF": push_changes["branch"],
                "HEAD_REF": "feature-123",
                "PR_ID": "1",
                "COMMIT_ID": push_changes["commit_id"],
                "GITHUB_MERGE_LOCK_SSM_KEY": mut_output["merge_lock_ssm_key"],
                "AURORA_CLUSTER_ARN": mut_output["metadb_arn"],
                "AURORA_SECRET_ARN": mut_output["metadb_secret_manager_ci_arn"],
                "TRIGGER_SF_FUNCTION_NAME": mut_output["trigger_sf_function_name"],
                "METADB_NAME": mut_output["metadb_name"],
                "LOG_URL_PREFIX": mut_output["ecs_log_url_prefix"],
                "LOG_STREAM_PREFIX": mut_output[
                    "create_deploy_stack_log_stream_prefix"
                ],
            },
            local_task_env_vars={
                "create_stack_GITHUB_TOKEN": os.environ["GITHUB_TOKEN"],
                "create_stack_SCAN_TYPE": "graph",
                "create_stack_COMMIT_STATUS_CONFIG": mut_output["commit_status_config"],
            },
            compose_files=[
                os.path.dirname(__file__) + "/docker-compose.local-network.yml"
            ],
        )

        with aurora_data_api.connect(
            aurora_cluster_arn=mut_output["metadb_arn"],
            secret_arn=mut_output["metadb_secret_manager_master_arn"],
            database=mut_output["metadb_name"],
            rds_data_client=rds_data,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                SELECT array_agg(cfg_path::TEXT)
                FROM {mut_output["metadb_schema"]}.executions
                WHERE commit_id = '{push_changes["commit_id"]}'
                """
                )
                results = cur.fetchone()[0]
                actual_cfg_paths = [] if results is None else [id for id in results]

        log.info("Assert that all expected cfg_paths are within executions table")
        assert len(expected_cfg_paths) == len(actual_cfg_paths) and sorted(
            expected_cfg_paths
        ) == sorted(actual_cfg_paths)

        repo = gh.get_repo(mut_output["repo_full_name"])
        status = [
            status
            for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
            if status.context == mut_output["create_deploy_stack_status_check_name"]
        ][0]

        log.info("Assert that expected commit status state is sent")
        assert status.state == "success"

    @pytest.mark.skip()
    def test_failed_execution(self, mut_output, push_changes):
        with pytest.raises(Exception):
            run_task(mut_output, overwrite_compose=True)

        actual_cfg_paths = get_commit_cfg_paths(push_changes["commit_id"], mut_output)

        log.info(
            "Assert that are no records within the execution table from the testing commit ID"
        )
        assert len(actual_cfg_paths) == 0

        repo = gh.get_repo(mut_output["repo_full_name"])
        status = [
            status
            for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
            if status.context == mut_output["create_deploy_stack_status_check_name"]
        ][0]

        log.info("Assert that expected commit status state is sent")
        assert status.state == "failure"
