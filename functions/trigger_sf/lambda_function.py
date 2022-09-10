import os
import sys
import logging
import json
import boto3
import aurora_data_api
from pprint import pformat
import github

sys.path.append(os.path.dirname(__file__) + "/..")
from common_lambda.utils import ClientException

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

sf = boto3.client("stepfunctions")
ssm = boto3.client("ssm")
rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)


def _execution_finished(cur, execution: map, account_id) -> None:
    """
    Updates the Step Function's associated metadb record status and handles
    the case where the Step Function execution fails or is aborted

    Arguments:
        execution: Cloudwatch event payload associated with finished Step
            Function execution
        account_id: AWS account ID that the Step Function machine is hosted in
    """

    log.info("Updating execution record status")
    cur.execute(
        f"""
    UPDATE executions
    SET "status" = '{execution['status']}'
    WHERE execution_id = '{execution['execution_id']}'
    """
    )

    commit_status_config = json.loads(
        ssm.get_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"])["Parameter"][
            "Value"
        ]
    )

    log.debug(f"Commit status config:\n{pformat(commit_status_config)}")

    if commit_status_config["Execution"]:
        log.info("Sending commit status")

        token = ssm.get_parameter(
            Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
        )["Parameter"]["Value"]

        if execution["status"] in ["failed", "aborted"]:
            state = "failure"
        else:
            state = "success"

        gh = github.Github(token)
        gh.get_repo(os.environ["REPO_FULL_NAME"]).get_commit(
            execution["commit_id"]
        ).create_status(
            state=state,
            description="Step Function Execution",
            context=execution["execution_id"],
            target_url=f"https://{os.environ['AWS_REGION']}.console.aws.amazon.com/states/home?region={os.environ['AWS_REGION']}#/executions/details/arn:aws:states:{os.environ['AWS_REGION']}:{account_id}:execution:{os.environ['STATE_MACHINE_ARN'].split(':')[-1]}:{execution['execution_id']}",
        )

    if not execution["is_rollback"] and execution["status"] in ["failed", "aborted"]:
        log.info("Aborting all deployments for commit")
        cur.execute(
            f"""
        UPDATE executions
        SET "status" = 'aborted'
        WHERE "status" IN ('waiting', 'running')
        AND commit_id = '{execution['commit_id']}'
        AND is_rollback = false
        RETURNING execution_id
        """
        )

        results = cur.fetchall()
        log.debug(f"Results: {results}")
        if len(results) != 0:
            aborted_ids = [r[0] for r in results]

            log.info("Aborting Step Function executions")
            for id in aborted_ids:
                log.debug(f"Execution ID: {id}")
                try:
                    execution_arn = [
                        execution["executionArn"]
                        for execution in sf.list_executions(
                            stateMachineArn=os.environ["STATE_MACHINE_ARN"]
                        )["executions"]
                        if execution["name"] == id
                    ][0]
                except IndexError:
                    log.debug(
                        f"Step Function execution for execution ID does not exist: {id}"
                    )
                    continue
                log.debug(f"Execution ARN: {execution_arn}")

                sf.stop_execution(
                    executionArn=execution_arn,
                    error="DependencyError",
                    cause=f'cfg_path dependency failed: {execution["cfg_path"]}',
                )

        log.info("Creating rollback executions if needed")
        with open(
            f"{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_rollback_stack.sql",
            "r",
        ) as f:
            cur.execute(f.read().format(commit_id=execution["commit_id"]))
            results = cur.fetchall()
            log.debug(f"Results:\n{results}")
            if len(results) != 0:
                rollback_records = [
                    dict(zip([desc.name for desc in cur.description], record))
                    for record in results
                ]
                log.debug(f"Rollback records:\n{rollback_records}")

    elif execution["is_rollback"] is True and execution["status"] in [
        "failed",
        "aborted",
    ]:
        # not aborting waiting and running rollback executions to allow CI flow
        # to continue after admin intervention since future PR deployments
        # will break if the new provider resources are not destroyed beforehand
        raise ClientException(
            "Rollback execution failed -- User with administrative privileges will need to manually fix configuration"
        )


def _start_sf_executions(cur) -> None:
    """
    Selects execution records to pass to Step Function deployment flow and
    starts the Step Function executions

    Arguments:
        cur: Database cursor
    """

    log.info(
        "Getting executions that have all account dependencies and terragrunt dependencies met"
    )
    try:
        with open(
            f"{os.path.dirname(os.path.realpath(__file__))}/sql/select_target_execution_ids.sql"
        ) as f:
            cur.execute(f.read())
            cur.execute("SELECT get_target_execution_ids()")
    except aurora_data_api.exceptions.DatabaseError as e:
        log.error(e, exc_info=True)
        log.error(
            f'Merge lock value: {ssm.get_parameter(Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"])["Parameter"]["Value"]}'
        )
        sys.exit(1)

    results = cur.fetchone()
    log.debug(f"Results: {results}")

    if results[0] is None:
        log.info("No executions are ready")
        return
    else:
        ids = results[0]

    log.debug(f"IDs: {ids}")
    log.info(f"Count: {len(ids)}")

    if "DRY_RUN" in os.environ:
        log.info("DRY_RUN was set -- skip starting sf executions")
    else:
        # TODO: replace built-in `id` var (use id_ ?)
        for id in ids:
            log.info(f"Execution ID: {id}")

            log.debug("Updating execution status to running")
            cur.execute(
                f"""
                UPDATE executions
                SET status = 'running'
                WHERE execution_id = '{id}'
                RETURNING *
            """
            )

            sf_input = json.dumps(
                dict(zip([desc.name for desc in cur.description], cur.fetchone()))
            )
            log.debug(f"SF input:\n{sf_input}")

            log.info("Starting sf execution")
            sf.start_execution(
                stateMachineArn=os.environ["STATE_MACHINE_ARN"], name=id, input=sf_input
            )


def lambda_handler(event, context):
    """
    Runs Step Function deployment flow or resets SSM Parameter Store merge
    lock value if deployment stack is empty
    """

    log.debug(f"Event:\n{event}")
    try:
        with aurora_data_api.connect(
            aurora_cluster_arn=os.environ["AURORA_CLUSTER_ARN"],
            secret_arn=os.environ["AURORA_SECRET_ARN"],
            database=os.environ["METADB_NAME"],
            rds_data_client=rds_data_client,
        ) as conn:
            with conn.cursor() as cur:
                if "execution" in event:
                    execution = event["execution"]
                    log.info(
                        f'Triggered via Step Function Event:\n{event["execution"]}'
                    )
                    if execution["output"] is None:
                        # use step function execution input since the output is none when execution is aborted
                        record = {
                            **json.loads(execution["input"]),
                            **{"status": execution["status"].lower()},
                        }
                    else:
                        record = json.loads(execution["output"])
                    _execution_finished(
                        cur, record, context.invoked_function_arn.split(":")[4]
                    )

                log.info("Checking if commit executions are in progress")
                cur.execute(
                    "SELECT 1 FROM executions WHERE status IN ('waiting', 'running')"
                )

                if cur.rowcount > 0:
                    log.info("Starting Step Function Deployment Flow")
                    _start_sf_executions(cur)
                else:
                    log.info(
                        "No executions are waiting or running -- unlocking merge action within target branch"
                    )
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
