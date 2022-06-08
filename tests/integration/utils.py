import time
import logging
import datetime
import boto3

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TimeoutError(Exception):
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
