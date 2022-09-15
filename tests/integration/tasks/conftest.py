import os
import pytest
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_generate_tests(metafunc):
    if "terra" in metafunc.fixturenames:
        metafunc.parametrize(
            "terra",
            [
                pytest.param(
                    {
                        "binary": "terragrunt",
                        "skip_teardown": True,
                        "env": {
                            "TF_VAR_approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
                            "TF_VAR_approval_request_sender_email": "fakesender@fake.com",
                            "TF_VAR_create_approval_sender_policy": "false",
                        },
                        "tfdir": f"{os.path.dirname(os.path.realpath(__file__))}/../../fixtures/terraform/mut/basic",
                    },
                )
            ],
            indirect=True,
            scope="session",
        )
    if "terra_setup" in metafunc.fixturenames:
        metafunc.parametrize(
            "terra_setup", [{"cleanup_on_exit": False}], indirect=True, scope="session"
        )
        # metafunc.parametrize("terra_setup", [{"cleanup_on_exit": os.environ.get("IS_REMOTE") == None}], indirect=True, scope="session")


@pytest.fixture()
def mut_output(terra_apply, terra_output):
    return {k: v["value"] for k, v in terra_output.items()}
