import os
import logging
import pytest
import sys
import uuid
import github

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


@pytest.fixture
def repo():
    name = f"mut-terraform-aws-infrastructure-live-{uuid.uuid4()}"
    gh = github.Github(os.environ["TF_VAR_testing_github_token"], retry=3).get_user()

    log.info(f"Creating testing repo: {name}")
    repo = gh.create_repo(name)

    yield repo.name

    log.info("Deleting testing repo")
    repo.delete()


@pytest.mark.parametrize(
    "terraform_version,tf",
    [("1.0.0", f"{os.path.dirname(os.path.realpath(__file__))}/fixtures")],
    indirect=True,
)
def test_plan(tf, terraform_version, repo):
    """
    Ensure that the Terraform module produces a valid Terraform plan with just
    the module's required variables defined
    """
    # add TF_VARS to tf obj env so TF_VARS are available for tf destroy cmd
    tf.env.update({"TF_VAR_repo_name": repo})

    log.info("Getting testing tf plan")
    out = tf.plan(output=True)
    log.debug(out)
