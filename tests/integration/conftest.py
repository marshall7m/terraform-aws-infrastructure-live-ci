import os
import logging
import uuid

import requests
import pytest
import github
import tftest
from tests.helpers.utils import push

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_addoption(parser):
    parser.addoption(
        "--skip-moto-reset", action="store_true", help="skips resetting moto server"
    )

    parser.addoption(
        "--setup-reset-moto-server",
        action="store_true",
        help="Resets moto server on session setup",
    )


def pytest_generate_tests(metafunc):
    tf_versions = [pytest.param("latest")]
    if "terraform_version" in metafunc.fixturenames:
        tf_versions = [pytest.param("latest")]
        metafunc.parametrize(
            "terraform_version",
            tf_versions,
            indirect=True,
            scope="session",
            ids=[f"tf_{v.values[0]}" for v in tf_versions],
        )

    if "tf" in metafunc.fixturenames:
        metafunc.parametrize(
            "tf",
            [f"{os.path.dirname(__file__)}/fixtures"],
            indirect=True,
            scope="session",
        )


@pytest.fixture(scope="session")
def reset_moto_server(request):
    if not os.environ.get("IS_REMOTE", False):
        reset = request.config.getoption("setup_reset_moto_server")
        if reset:
            log.info("Resetting moto server on setup")
            requests.post(f"{os.environ['MOTO_ENDPOINT_URL']}/moto-api/reset")

    yield None

    if os.environ.get("IS_REMOTE", False):
        skip = request.config.getoption("skip_moto_reset")
        if skip:
            log.info("Skip resetting moto server")
        else:
            log.info("Resetting moto server")
            requests.post(f"{os.environ['MOTO_ENDPOINT_URL']}/moto-api/reset")


@pytest.fixture(scope="session")
def mut_output(request, reset_moto_server):
    cache_dir = str(request.config.cache.makedir("tftest"))
    log.info(f"Caching Tftest return results to {cache_dir}")

    tf = tftest.TerragruntTest(
        env={
            "TF_VAR_approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
            "TF_VAR_approval_request_sender_email": "fakesender@fake.com",
            "TF_VAR_create_approval_sender_policy": "false",
        },
        tfdir=f"{os.path.dirname(os.path.realpath(__file__))}/../fixtures/terraform/mut/basic",
        enable_cache=True,
        cache_dir=cache_dir,
    )

    tf.setup(cleanup_on_exit=True, use_cache=True)
    tf.apply(auto_approve=True, use_cache=True)

    return {k: v["value"] for k, v in tf.output(use_cache=True).items()}


@pytest.fixture
def push_changes(mut_output, request):
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])
    branch = f"test-{uuid.uuid4()}"
    repo = gh.get_repo(mut_output["repo_full_name"])

    yield {
        "commit_id": push(repo, branch, request.param),
        "branch": branch,
        "changes": request.param,
    }

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()
