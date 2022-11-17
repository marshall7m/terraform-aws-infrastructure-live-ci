import sys
import os
import json
import logging

import aurora_data_api
import boto3

sys.path.append(os.path.dirname(__file__))

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))
rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)


def update_vote(execution_id: str, action: str, voter: str, task_token: str):
    log.info("Updating vote count")
    with aurora_data_api.connect(
        aurora_cluster_arn=os.environ["AURORA_CLUSTER_ARN"],
        secret_arn=os.environ["AURORA_SECRET_ARN"],
        database=os.environ["METADB_NAME"],
        rds_data_client=rds_data_client,
    ) as conn:
        with conn.cursor() as cur:
            with open(
                f"{os.path.dirname(os.path.realpath(__file__))}/update_vote.sql",  # noqa: E501
                "r",
            ) as f:
                cur.execute(
                    f.read().format(
                        action=action,
                        recipient=voter,
                        execution_id=execution_id,
                    )
                )
                results = cur.fetchone()
                if results is None:
                    raise ValueError(
                        f"Record with execution ID: {execution_id} does not exist"
                    )
                record = dict(
                    zip(
                        [
                            "status",
                            "approval_voters",
                            "min_approval_count",
                            "rejection_voters",
                            "min_rejection_count",
                        ],
                        list(results),
                    )
                )

    log.debug(f"Record:\n{json.dumps(record, indent=4)}")
    if (
        len(record["approval_voters"]) == record["min_approval_count"]
        or len(record["rejection_voters"]) == record["min_rejection_count"]
    ):
        log.info("Voter count meets requirement")
        log.info("Sending task token to Step Function Machine")
        sf.send_task_success(
            taskToken=task_token,
            output=json.dumps(action),
        )
