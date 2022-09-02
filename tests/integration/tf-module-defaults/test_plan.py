import os
import logging
import pytest
import sys
import uuid

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


@pytest.mark.parametrize(
    "terraform_version,tf,repo",
    [
        (
            "1.0.0",
            f"{os.path.dirname(os.path.realpath(__file__))}/fixtures",
            f"mut-terraform-aws-infrastructure-live-{uuid.uuid4()}",
        )
    ],
    indirect=True,
)
def test_plan(tf, terraform_version, repo):
    """
    Ensure that the Terraform module produces a valid Terraform plan with just
    the module's required variables defined
    """
    # add TF_VARS to tf obj env so TF_VARS are available for tf destroy cmd
    tf.env.update({"TF_VAR_repo_name": repo.full_name})

    log.info("Getting testing tf plan")
    out = tf.plan(output=True)
    log.debug(out)


@pytest.mark.parametrize(
    "terraform_version,tf,repo",
    [
        (
            "1.0.0",
            f"{os.path.dirname(os.path.realpath(__file__))}/fixtures",
            f"mut-terraform-aws-infrastructure-live-{uuid.uuid4()}",
        )
    ],
    indirect=True,
)
def test_apply(tf, terraform_version, repo):
    """
    Ensure that can be successfully applied with just
    the module's required variables defined
    """
    # add TF_VARS to tf obj env so TF_VARS are available for tf destroy cmd
    tf.env.update({"TF_VAR_repo_name": repo.full_name})

    log.info("Running Terraform apply")
    out = tf.apply(auto_approve=True)
    log.debug(out)
