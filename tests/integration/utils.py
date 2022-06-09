import time
import logging
import datetime
import boto3
import sys


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TimeoutError(Exception):
    pass


class ClientException(Exception):
    pass


def lambda_invocation_count(function_name, start_time, end_time=None):
    """
    Returns the number of times a Lambda Function has runned since the passed start_time

    Argruments:
        function_name: Name of the AWS Lambda function
        refresh: Determines if a refreshed invocation count should be returned. If False, returns the locally stored invocation count.
    """
    invocations = []
    if not end_time:
        end_time = datetime.datetime.now(datetime.timezone.utc)

    log.debug(f"Start Time: {start_time} -- End Time: {end_time}")

    cw = boto3.client("cloudwatch")

    response = cw.get_metric_statistics(
        Namespace="AWS/Lambda",
        MetricName="Invocations",
        Dimensions=[{"Name": "FunctionName", "Value": function_name}],
        StartTime=start_time,
        EndTime=end_time,
        Period=5,
        Statistics=["SampleCount"],
        Unit="Count",
    )
    for data in response["Datapoints"]:
        invocations.append(data["SampleCount"])

    return len(invocations)


def wait_for_lambda_invocation(function_name, start_time, expected_count=1, timeout=60):
    """Waits for Lambda's completed invocation count to be more than the current invocation count stored"""

    timeout = time.time() + timeout
    actual_count = lambda_invocation_count(function_name, start_time)
    log.debug(f"Refreshed Count: {actual_count}")

    log.debug(f"Waiting on Lambda Function: {function_name}")
    log.debug(f"Expected count: {expected_count}")
    while actual_count < expected_count:
        if time.time() > timeout:
            raise TimeoutError(f"{function_name} was not invoked")
        time.sleep(5)
        actual_count = lambda_invocation_count(function_name, start_time)
        log.debug(f"Refreshed Count: {actual_count}")


def get_build_finished_status(name: str, ids=[], filters={}) -> str:
    """
    Waits for a CodeBuild project build to finish and returns the status

    Arguments:
        name: Name of the CodeBuild project
        ids: Pre-existing CodeBuild project build IDs to get the statuses for
        filters: Attributes builds need to have in order to return their associated statuses.
            All filter attributes need to be matched for the build ID to be chosen. These
            attribute are in regards to the response return by client.batch_get_builds().
    """
    cb = boto3.client("codebuild")
    statuses = ["IN_PROGRESS"]

    if len(ids) == 0:
        ids = cb.list_builds_for_project(projectName=name, sortOrder="DESCENDING")[
            "ids"
        ]

        if len(ids) == 0:
            log.error(f"No builds have runned for project: {name}")
            sys.exit(1)

        log.debug(f"Build Filters:\n{filters}")
        for build in cb.batch_get_builds(ids=ids)["builds"]:
            for key, value in filters.items():
                if build.get(key, None) != value:
                    ids.remove(build["id"])
                    break
        if len(ids) == 0:
            log.error("No builds have met provided filters")
            sys.exit(1)

    log.debug(f"Getting build statuses for the following IDs:\n{ids}")
    while "IN_PROGRESS" in statuses:
        time.sleep(15)
        statuses = []
        for build in cb.batch_get_builds(ids=ids)["builds"]:
            statuses.append(build["buildStatus"])

    return statuses


def get_latest_log_stream_errs(log_group: str, start_time=None, end_time=None) -> list:
    """
    Gets a list of log events that contain the word `ERROR` within the latest stream of the CloudWatch log group

    Arguments:
        log_group: CloudWatch log group name
        start_time:  Start of the time range in milliseconds UTC
        end_time:  End of the time range in milliseconds UTC
    """
    logs = boto3.client("logs")

    stream = logs.describe_log_streams(
        logGroupName=log_group, orderBy="LastEventTime", descending=True, limit=1
    )["logStreams"][0]["logStreamName"]

    log.debug(f"Latest Stream: {stream}")

    log.info("Searching latest log stream for any errors")
    if start_time and end_time:
        log.debug(f"Start Time: {start_time}")
        log.debug(f"End Time: {end_time}")
        return logs.filter_log_events(
            logGroupName=log_group,
            logStreamNames=[stream],
            filterPattern="ERROR",
            startTime=start_time,
            endTime=end_time,
        )["events"]
    else:
        return logs.filter_log_events(
            logGroupName=log_group, logStreamNames=[stream], filterPattern="ERROR"
        )["events"]


def get_execution_arn(arn: str, execution_id: str) -> int:
    """
    Gets the task ID for a given Step Function execution type and name.
    If the execution type and name is not found, None is returned

    Arguments:
        arn: ARN of the Step Function execution
        execution_id: Name of the Step Function execution
        task_name: Task name within the Step Function definition
    """
    sf = boto3.client("stepfunctions")
    for execution in sf.list_executions(stateMachineArn=arn)["executions"]:
        if execution["name"] == execution_id:
            return execution["executionArn"]

    ClientException(f"No Step Function execution exists with name: {execution_id}")


def get_terra_run_status_event(execution_arn, task_name):
    sf = boto3.client("stepfunctions")

    log.info(f"Waiting for Step Function task to finish: {task_name}")
    finished_task = False
    while not finished_task:
        time.sleep(10)

        events = sf.get_execution_history(
            executionArn=execution_arn, includeExecutionData=True
        )["events"]

        for event in events:
            if event.get("stateExitedEventDetails", {}).get("name", None) == task_name:
                log.debug("Task finished")
                # the task before the stateExitedEventDetails event contains the task status
                return [e for e in events if e["id"] == event["id"] - 1][0]
