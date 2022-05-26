import os
import logging
import pytest
import sys

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


@pytest.mark.parametrize(
    "tf", [f"{os.path.dirname(os.path.realpath(__file__))}/fixtures"], indirect=True
)
@pytest.mark.parametrize("terraform_version", ["1.0.0"], indirect=True)
def test_plan(tf):
    """Ensure that the Terraform module produces a valid Terraform plan with just the module's required variables defined"""
    log.info("Getting testing tf plan")
    out = tf.plan(output=True)
    log.debug(out)
