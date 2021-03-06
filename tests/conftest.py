import pytest
import os
import datetime
import re
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_addoption(parser):
    parser.addoption(
        "--until-aws-exp",
        action="store",
        default=os.environ.get("UNTIL_AWS_EXP", False),
        help="The least amount of time until the AWS session token expires in minutes (e.g. 10m) or hours (e.g. 2h)",
    )


@pytest.fixture(scope="session", autouse=True)
def aws_session_expiration_check(request):
    """
    Setup fixture that ensures that the AWS session credentials are atleast valid for a defined amount of time so
    that they do not expire during tests
    """
    until_exp = request.config.getoption("until_aws_exp")
    if until_exp:
        log.info(
            "Checking if time until AWS session token expiration meets requirement"
        )
        log.debug(f"Input: {until_exp}")
        if os.environ.get("AWS_SESSION_EXPIRATION", False):
            log.debug(f'AWS_SESSION_EXPIRATION: {os.environ["AWS_SESSION_EXPIRATION"]}')
            exp = datetime.datetime.strptime(
                os.environ["AWS_SESSION_EXPIRATION"], "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=datetime.timezone.utc)

            actual_until_exp_seconds = int(
                exp.timestamp()
                - datetime.datetime.now(datetime.timezone.utc).timestamp()
            )

            until_exp_groups = re.search(r"(\d+(?=h))|(\d+(?=m))", until_exp)
            if until_exp_groups.group(1):
                until_exp = int(until_exp_groups.group(1))
                log.info(
                    f'Test(s) require atleast: {until_exp} hour{"s"[:until_exp^1]}'
                )
                diff_hours = int(
                    datetime.timedelta(seconds=actual_until_exp_seconds)
                    / datetime.timedelta(hours=1)
                )
                log.info(
                    f'Time until expiration: {diff_hours} hour{"s"[:diff_hours^1]}'
                )
                until_exp_seconds = until_exp * 60 * 60
            elif until_exp_groups.group(2):
                until_exp = int(until_exp_groups.group(2))
                log.info(
                    f'Test(s) require atleast: {until_exp} minute{"s"[:until_exp^1]}'
                )
                diff_minutes = datetime.timedelta(
                    seconds=actual_until_exp_seconds
                ) // datetime.timedelta(minutes=1)
                log.info(
                    f'Time until expiration: {diff_minutes} minute{"s"[:diff_minutes^1]}'
                )
                until_exp_seconds = until_exp * 60

            log.debug(f"Actual seconds until expiration: {actual_until_exp_seconds}")
            log.debug(f"Required seconds until expiration: {until_exp_seconds}")
            if actual_until_exp_seconds < until_exp_seconds:
                pytest.skip(
                    "AWS session token needs to be refreshed before running tests"
                )
        else:
            log.info("$AWS_SESSION_EXPIRATION is not set -- skipping check")
    else:
        log.info("Neither --until-aws-exp nor $UNTIL_AWS_EXP was set -- skipping check")
