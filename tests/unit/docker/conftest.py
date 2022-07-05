import pytest
import os
import logging
import git
import re
from docker.src.common.utils import subprocess_run
from tests.helpers.utils import insert_records

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def mock_subprocess_run(cmd: str, check=True):
    """
    Mock wrapper that removes --terragrunt-iam-role flag from all Terragrunt related commands passed to subprocess_run().
    Given tests are provisioning terraform resources locally, assuming IAM roles are not needed.
    """
    cmd = re.sub(r"\s--terragrunt-iam-role\s+.+?(?=\s|$)", "", cmd)
    return subprocess_run(cmd, check)


@pytest.fixture(scope="module")
def account_dim(conn, cur):
    """Creates account records within local db"""
    results = insert_records(
        conn,
        "account_dim",
        [
            {
                "account_name": "dev",
                "account_path": "directory_dependency/dev-account",
                "account_deps": ["shared-services"],
            },
            {
                "account_name": "shared-services",
                "account_path": "directory_dependency/shared-services-account",
                "account_deps": [],
            },
        ],
    )

    yield results

    cur.execute("TRUNCATE account_dim")


@pytest.fixture(scope="module")
def base_git_repo(tmp_path_factory):
    """Clones template infrastructure-live repo from GitHub into local tmp dir"""
    root_dir = str(tmp_path_factory.mktemp("test-create-deploy-stack-"))
    yield git.Repo.clone_from(
        f'https://oauth2:{os.environ["TF_VAR_testing_unit_github_token"]}@github.com/marshall7m/infrastructure-live-testing-template.git',
        root_dir,
    )


@pytest.fixture(scope="function")
def git_repo(tmp_path_factory, base_git_repo):
    """Clones template infrastructure-live repo from tmp dir to another tmp dir for each test function. Reason for fixture is to reduce amount of remote clones needed for testing"""
    param_git_dir = str(tmp_path_factory.mktemp("test-create-deploy-stack-param-"))
    yield git.Repo.clone_from(
        str(base_git_repo.git.rev_parse("--show-toplevel")), param_git_dir
    )


@pytest.fixture(scope="function")
def repo_changes(request, git_repo):
    """
    Creates Terraform files within the test's version of the local repo

    Arguments:
    request.param: Map keys consisting of filepaths that are relative to the root directory of the repo and
        string content to write to the directory path
    """
    for path, content in request.param.items():
        abs_path = str(git_repo.git.rev_parse("--show-toplevel")) + "/" + path
        log.debug(f"Creating file: {abs_path}")
        with open(abs_path, "w") as text_file:
            text_file.write(content)

    return request.param


tf_versions = [
    pytest.param("latest"),
    pytest.param("0.13.0"),
]

tg_versions = [
    pytest.param("latest"),
    pytest.param("0.31.0"),
]


def pytest_generate_tests(metafunc):

    if "terraform_version" in metafunc.fixturenames:
        metafunc.parametrize(
            "terraform_version",
            tf_versions,
            scope="function",
            ids=[f"tf_{v.values[0]}" for v in tf_versions],
            indirect=True,
        )

    if "terragrunt_version" in metafunc.fixturenames:
        metafunc.parametrize(
            "terragrunt_version",
            tg_versions,
            scope="function",
            ids=[f"tg_{v.values[0]}" for v in tg_versions],
            indirect=True,
        )