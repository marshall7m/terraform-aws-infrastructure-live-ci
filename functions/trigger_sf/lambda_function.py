import os
import sys
import logging
import json
from typing import List

import boto3
import aurora_data_api
import github

sys.path.append(os.path.dirname(__file__))
from utils import get_logger, ClientException

log = get_logger()
log.setLevel(logging.DEBUG)

sf = boto3.client("stepfunctions")
ssm = boto3.client("ssm")
rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)


class ExecutionFinished:
    def __init__(
        self,
        execution_id: str,
        status: str,
        is_rollback: bool,
        commit_id: str,
        cfg_path: str,
    ):
        """
        Handles AWS EventBridge rule event that's triggered by finished Step
        Function executions

        Arguments:
            status: Step Funciton execution event data from EventBridge rule
            account_id: AWS account ID of the Step Function machine
        """
        self.execution_id = execution_id
        self.status = status
        self.is_rollback = is_rollback
        self.commit_id = commit_id
        self.cfg_path = cfg_path

    def update_status(self) -> None:
        """Updates finished Step Function execution's associated metadb record status"""
        with aurora_data_api.connect(
            database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
        ) as conn, conn.cursor() as cur:
            log.info("Updating execution record status")
            cur.execute(
                f"""
            UPDATE executions
            SET "status" = '{self.status}'
            WHERE execution_id = '{self.execution_id}'
            """
            )

    def send_commit_status(self) -> None:
        """Sends a GitHub commit status to the execution's associated commit"""
        token = ssm.get_parameter(
            Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
        )["Parameter"]["Value"]

        if self.status in ["failed", "aborted"]:
            state = "failure"
        else:
            state = "success"

        gh = github.Github(token)
        gh.get_repo(os.environ["REPO_FULL_NAME"]).get_commit(
            self.commit_id
        ).create_status(
            state=state,
            description="Step Function Execution",
            context=self.execution_id,
            target_url=f"https://{os.environ['AWS_REGION']}.console.aws.amazon.com/states/home?region={os.environ['AWS_REGION']}#/executions/details/arn:aws:states:{os.environ['AWS_REGION']}:{self.account_id}:execution:{os.environ['STATE_MACHINE_ARN'].split(':')[-1]}:{self.execution_id}",
        )

    def create_rollback_records(self) -> None:
        with aurora_data_api.connect(
            database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
        ) as conn, conn.cursor() as cur:
            with open(
                f"{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_rollback_stack.sql",
                "r",
            ) as f:
                cur.execute(f.read().format(commit_id=self.commit_id))
                results = cur.fetchall()
                log.debug(f"Results:\n{results}")
                if len(results) != 0:
                    rollback_records = [
                        dict(zip([desc.name for desc in cur.description], record))
                        for record in results
                    ]
                    log.debug(f"Rollback records:\n{rollback_records}")

    def abort_sf_executions(self, ids):
        sf = boto3.client("stepfunctions")
        log.info("Aborting Step Function executions")
        for _id in ids:
            log.debug(f"Execution ID: {_id}")
            try:
                print(sf)
                execution_arn = [
                    execution["executionArn"]
                    for execution in sf.list_executions(
                        stateMachineArn=os.environ["STATE_MACHINE_ARN"]
                    )["executions"]
                    if execution["name"] == _id
                ][0]
            except IndexError:
                log.debug(
                    f"Step Function execution for execution ID does not exist: {_id}"
                )
                continue
            log.debug(f"Execution ARN: {execution_arn}")

            sf.stop_execution(
                executionArn=execution_arn,
                error="DependencyError",
                cause=f"cfg_path dependency failed: {self.cfg_path}",
            )

    def abort_commit_records(self) -> List[str]:
        with aurora_data_api.connect(
            database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
        ) as conn, conn.cursor() as cur:
            cur.execute(
                f"""
            UPDATE executions
            SET "status" = 'aborted'
            WHERE "status" IN ('waiting', 'running')
            AND commit_id = '{self.commit_id}'
            AND is_rollback = false
            RETURNING execution_id
            """
            )

            results = cur.fetchall()

        log.debug(f"Results: {results}")
        return [r[0] for r in results if r[0] is not None]

    def handle_failed_execution(self) -> None:
        """
        Updates the Step Function's associated metadb record status and handles
        the case where the Step Function execution fails or is aborted
        """
        if self.status in ["failed", "aborted"]:
            if not self.is_rollback:
                log.info("Aborting all deployments for commit")
                aborted_ids = self.abort_commit_records()

                self.abort_sf_executions(aborted_ids)

                log.info("Creating rollback executions if needed")
                self.create_rollback_records()

            elif self.is_rollback:
                # not aborting waiting and running rollback executions to allow CI flow
                # to continue after admin intervention since future PR deployments
                # will break if the new provider resources are not destroyed beforehand
                raise ClientException(
                    "Rollback execution failed -- User with administrative privileges will need to manually fix configuration"
                )


def check_executions_running() -> bool:
    """
    Returns True if any execution records have a status of waiting or running
    and False otherwise
    """
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        log.info("Checking if commit executions are in progress")
        cur.execute("SELECT 1 FROM executions WHERE status IN ('waiting', 'running')")

        if cur.rowcount > 0:
            return True

        return False


def get_target_execution_ids() -> List[str]:
    """
    Returns list of execution IDs that have all account dependencies and
    terragrunt dependencies met
    """
    try:
        with aurora_data_api.connect(
            database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
        ) as conn, conn.cursor() as cur:
            with open(
                f"{os.path.dirname(os.path.realpath(__file__))}/sql/select_target_execution_ids.sql"
            ) as f:
                cur.execute(f.read())
                cur.execute("SELECT get_target_execution_ids()")
                results = cur.fetchone()

    except aurora_data_api.exceptions.DatabaseError as e:
        log.error(e, exc_info=True)
        log.error(
            f'Merge lock value: {ssm.get_parameter(Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"])["Parameter"]["Value"]}'
        )
        raise e

    if results[0] is None:
        return []

    return results[0]


def start_sf_executions() -> None:
    ids = get_target_execution_ids()
    log.debug(f"IDs: {ids}")
    log.debug(f"Count: {len(ids)}")

    if len(ids) == 0:
        log.info("No executions are ready")
        return

    if "DRY_RUN" in os.environ:
        log.info("DRY_RUN was set -- skip starting sf executions")
    else:
        with aurora_data_api.connect(
            database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
        ) as conn, conn.cursor() as cur:
            for _id in ids:
                log.info(f"Execution ID: {_id}")

                log.debug("Updating execution status to running")
                cur.execute(
                    f"""
                    UPDATE executions
                    SET status = 'running'
                    WHERE execution_id = '{_id}'
                    RETURNING *
                """
                )

                sf_input = json.dumps(
                    dict(zip([desc.name for desc in cur.description], cur.fetchone()))
                )
                log.debug(f"SF input:\n{sf_input}")

                log.info("Starting sf execution")
                sf.start_execution(
                    stateMachineArn=os.environ["STATE_MACHINE_ARN"],
                    name=_id,
                    input=sf_input,
                )


def lambda_handler(event, context):
    """
    Updates finished Step Function execution status if Lambda Function was triggered by EventBridge.
    Otherwise runs the Step Function deployment flow or resets the SSM Parameter Store merge
    lock value if deployment stack is empty.
    """
    log.debug(f"Event:\n{event}")
    try:
        if event.get("execution"):
            output = event["execution"].get("output")
            if output:
                execution = json.loads(output)
            else:
                # use step function execution input since the output is none when execution is aborted
                execution = {
                    **json.loads(event["execution"]["input"]),
                    **{"status": event["execution"]["status"].lower()},
                }

            log.info(f"Triggered via Step Function Event:\n{execution}")

            send_commit_status = json.loads(
                ssm.get_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"])[
                    "Parameter"
                ]["Value"]
            ).get("Execution")

            execution = ExecutionFinished(
                status=execution["status"],
                is_rollback=execution["is_rollback"],
                commit_id=execution["commit_id"],
                cfg_path=execution["cfg_path"],
                account_id=context.invoked_function_arn.split(":")[4],
            )

            execution.update_status()
            execution.send_commit_status(send_commit_status)
            execution.handle_failed_execution()

        running = check_executions_running()

        if running:
            log.info("Starting Step Function Deployment Flow")
            start_sf_executions()
        else:
            log.info("Unlocking merge action within target branch")
            ssm.put_parameter(
                Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
                Value="none",
                Type="String",
                Overwrite=True,
            )

        return {"statusCode": 200, "message": "Invocation was successful"}
    except Exception as e:
        log.error(e, exc_info=True)
        return {"statusCode": 500, "message": "Invocation was unsuccessful"}
