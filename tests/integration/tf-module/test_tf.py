import os
import logging
import pytest

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

muts = []


@pytest.mark.parametrize(
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
            marks=pytest.mark.skip(),
            id="defaults",
        ),
    ],
    indirect=True,
)
def test_plan(terra):
    """
    Ensure that the Terraform module produces a valid Terraform plan with just
    the module's required variables defined
    """
    log.info("Terraform plan:")
    log.debug(terra)
