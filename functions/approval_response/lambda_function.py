import boto3
import logging
import json
import os
import sys
import aurora_data_api
from pprint import pformat

sf = boto3.client("stepfunctions")

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def lambda_handler(event, context):
    """
    Updates the approval or rejection count associated with the
    Terragrunt path. If the minimum approval or rejection count is met,
    a successful task token is sent to associated AWS Step Function
    """
    log.info(event)

    action = event["body"]["action"]

    try:
        status = sf.describe_execution(executionArn=event["query"]["exId"])["status"]
        if status == "RUNNING":
            log.info("Updating vote count")
            # TODO: If query execution time is too long and
            #  causes downstream timeouts, invoke async lambda with
            #  query and return submission response from this function
            with aurora_data_api.connect(
                aurora_cluster_arn=os.environ["METADB_CLUSTER_ARN"],
                secret_arn=os.environ["METADB_SECRET_ARN"],
                database=os.environ["METADB_NAME"],
            ) as conn:
                with conn.cursor() as cur:
                    with open(
                        f"{os.path.dirname(os.path.realpath(__file__))}/update_vote.sql",  # noqa: E501
                        "r",
                    ) as f:
                        cur.execute(
                            f.read().format(
                                action=action,
                                recipient=event["body"]["recipient"],
                                execution_id=event["query"]["ex"],
                            )
                        )
                        try:
                            record = dict(
                                zip(
                                    [
                                        "status",
                                        "approval_voters",
                                        "min_approval_count",
                                        "rejection_voters",
                                        "min_rejection_count",
                                    ],
                                    list(cur.fetchone()),
                                )
                            )
                        except TypeError:
                            raise ClientException(
                                f'Record with execution ID: {event["query"]["ex"]} does not exist'  # noqa: E501
                            )
            log.debug(f"Record:\n{pformat(record)}")

            if (
                len(record["approval_voters"]) == record["min_approval_count"]
                or len(record["rejection_voters"]) == record["min_rejection_count"]
            ):
                log.info("Voter count meets requirement")

                log.info("Sending task token to Step Function Machine")
                sf.send_task_success(
                    taskToken=event["query"]["taskToken"],
                    output=json.dumps(action),  # noqa: E501
                )

            return {"statusCode": 200, "message": "Your choice has been submitted"}
        else:
            return {
                "statusCode": 410,
                "message": f"Approval submissions are not available anymore -- Execution Status: {status}",  # noqa: E501
            }
    except Exception as e:
        log.error(e, exc_info=True)
        return {"statusCode": 500, "message": "Error while processing approval action"}


class ClientException(Exception):
    """Wraps around client-related errors"""

    pass
