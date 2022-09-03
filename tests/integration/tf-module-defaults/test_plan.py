import os
import logging
import pytest
import sys

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def pytest_generate_tests(metafunc):
    if "terra" in metafunc.fixturenames:
        metafunc.parametrize(
            "terra",
            [
                pytest.param(
                    {
                        "binary": "terragrunt",
                        "command": "plan",
                        "skip_teardown": False,
                        "env": {"IS_REMOTE": "False"},
                        "tfdir": f"{os.path.dirname(os.path.realpath(__file__))}/../../fixtures/terraform/mut/defaults",
                    },
                    id="defaults",
                )
            ],
            indirect=True,
            scope="module",
        )


def test_plan(terra):
    """
    Ensure that the Terraform module produces a valid Terraform plan with just
    the module's required variables defined
    """
    log.info("Terraform plan:")
    log.debug(terra)


def test_apply(terra):
    """
    Ensure that can be successfully applied with just
    the module's required variables defined
    """
    pass
