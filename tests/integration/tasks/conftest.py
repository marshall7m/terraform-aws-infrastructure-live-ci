import os
import pytest
import github
import uuid
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
                            "IS_REMOTE": "False",
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

@pytest.fixture(scope="session")
def repo(request):
    gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)

    name = getattr(request, "param", f"test-repo-{uuid.uuid4()}")
    log.info(f"Creating repo: {name}")
    repo = gh.get_user().create_repo(name, auto_init=True)

    yield repo

    log.info(f"Deleting repo: {name}")
    repo.delete()

@pytest.fixture(scope="session")
def mut(repo, terra):
    terra.env = {**terra.env, **{"TF_VAR_repo_clone_url": repo.clone_url}}
    terra.setup(cleanup_on_exit=True)
    terra.apply(auto_approve=True)
    return terra