import time
import logging
import datetime
import boto3
import sys
from pprint import pformat
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TimeoutError(Exception):
    """Wraps around timeout-related errors"""

    pass


class ClientException(Exception):
    """Wraps around client-related errors"""

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


def get_latest_log_stream_errs(
    log_group: str, start_time=None, end_time=None, wait=5, timeout=30
) -> list:
    """
    Gets a list of log events that contain the word `ERROR` within the latest stream of the CloudWatch log group

    Arguments:
        log_group: CloudWatch log group name
        start_time:  Start of the time range in milliseconds UTC
        end_time:  End of the time range in milliseconds UTC
    """
    logs = boto3.client("logs")
    timeout = time.time() + timeout
    stream = None
    while not stream:
        if time.time() > timeout:
            raise TimeoutError(f"No stream exists within log group")
        try:
            stream = logs.describe_log_streams(
                logGroupName=log_group,
                orderBy="LastEventTime",
                descending=True,
                limit=1,
            )["logStreams"][0]["logStreamName"]
        except IndexError:
            log.debug(
                f"No stream exists within log group -- Retrying in {wait} seconds"
            )
            stream = None
            time.sleep(wait)

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
