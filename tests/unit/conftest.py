import pytest
import psycopg2
from psycopg2 import sql
import os
import timeout_decorator
import logging
import psycopg2.extras
import github

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture(scope="session")
def conn():
    """psycopg2 connection with auto commit set to True"""
    conn = psycopg2.connect(connect_timeout=10)
    conn.set_session(autocommit=True)

    yield conn
    conn.close()


@pytest.fixture(scope="session")
def cur(conn):
    """psycopg2 cursor that returns dictionary type results {column_name: value}"""
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    yield cur
    cur.close()


@timeout_decorator.timeout(30)
@pytest.fixture(scope="session")
def setup_metadb(cur):
    """Creates `account_dim` and `executions` table"""
    log.info("Creating metadb tables")
    with open(
        f"{os.path.dirname(os.path.realpath(__file__))}/../../sql/create_metadb_tables.sql",
        "r",
    ) as f:
        cur.execute(
            sql.SQL(f.read().replace("$", "")).format(
                metadb_schema=sql.Identifier("testing"),
                metadb_name=sql.Identifier(os.environ["PGDATABASE"]),
            )
        )
    yield None

    log.info("Dropping metadb tables")
    cur.execute("DROP TABLE IF EXISTS executions, account_dim")


@pytest.fixture(scope="function")
def truncate_executions(setup_metadb, cur):
    """Removes all rows from execution table after every test"""

    yield None

    log.info("Teardown: Truncating executions table")
    cur.execute("TRUNCATE executions")


@pytest.fixture()
def mock_conn(mocker, conn):
    """Patches AWS RDS client with psycopg2 client that connects to the local docker container Postgres database"""
    return mocker.patch("aurora_data_api.connect", return_value=conn, autospec=True)


@pytest.fixture(scope="function")
def aws_credentials():
    """
    Mocked AWS credentials needed to be set before importing Lambda Functions that define global boto3 clients.
    This prevents the region_name not specified errors.
    """
    os.environ["AWS_ACCESS_KEY_ID"] = os.environ.get("AWS_ACCESS_KEY_ID", "testing")
    os.environ["AWS_SECRET_ACCESS_KEY"] = os.environ.get(
        "AWS_SECRET_ACCESS_KEY", "testing"
    )
    os.environ["AWS_SECURITY_TOKEN"] = os.environ.get("AWS_SECURITY_TOKEN", "testing")
    os.environ["AWS_SESSION_TOKEN"] = os.environ.get("AWS_SESSION_TOKEN", "testing")
    os.environ["AWS_REGION"] = os.environ.get("AWS_REGION", "us-west-2")
    os.environ["AWS_DEFAULT_REGION"] = os.environ.get("AWS_DEFAULT_REGION", "us-west-2")


@pytest.fixture(scope="session")
def gh():
    return github.Github(os.environ["TF_VAR_testing_unit_github_token"], retry=3)


@pytest.fixture(scope="module")
def repo(gh, request):

    if type(request.param) == dict:
        if request.param["is_fork"]:
            log.info(f"Forking repo: {request.param['name']}")
            base = gh.get_repo(request.param["name"])
            repo = gh.get_user().create_fork(base)
    else:
        log.info(f"Creating repo: {request.param}")
        repo = gh.get_user().create_repo(request.param, auto_init=True)

    yield repo

    log.info(f"Deleting repo: {request.param}")
    repo.delete()


class ServerException(Exception):
    pass


def commit(repo, branch, changes, commit_message):
    elements = []
    for filepath, content in changes.items():
        log.debug(f"Creating file: {filepath}")
        blob = repo.create_git_blob(content, "utf-8")
        elements.append(
            github.InputGitTreeElement(
                path=filepath, mode="100644", type="blob", sha=blob.sha
            )
        )

    head_sha = repo.get_branch(branch).commit.sha
    base_tree = repo.get_git_tree(sha=head_sha)
    tree = repo.create_git_tree(elements, base_tree)
    parent = repo.get_git_commit(sha=head_sha)
    commit = repo.create_git_commit(commit_message, tree, [parent])

    return commit


def push(repo, branch, changes, commit_message="Adding test files"):
    try:
        ref = repo.get_branch(branch)
    except Exception:
        log.debug(f"Creating ref for branch: {branch}")
        ref = repo.create_git_ref(
            ref="refs/heads/" + branch,
            sha=repo.get_branch(repo.default_branch).commit.sha,
        )
        log.debug(f"Ref: {ref.ref}")

    commit_obj = commit(repo, branch, changes, commit_message)
    log.debug(f"Pushing commit ID: {commit_obj.sha}")
    ref.edit(sha=commit_obj.sha)

    return branch


@pytest.fixture
def pr(repo, request):
    """
    Creates the PR used for testing the function calls to the GitHub API.
    Current implementation creates all PR changes within one commit.
    """

    param = request.param[0]
    base_commit = repo.get_branch(param["base_ref"])
    head_ref = repo.create_git_ref(
        ref="refs/heads/" + param["head_ref"], sha=base_commit.commit.sha
    )
    commit_id = commit(
        repo, param["head_ref"], param["changes"], param["commit_message"]
    ).sha
    head_ref.edit(sha=commit_id)

    log.info("Creating PR")
    pr = repo.create_pull(
        title=param.get("title", f"test-{param['head_ref']}"),
        body=param.get("body", "Test PR"),
        base=param["base_ref"],
        head=param["head_ref"],
    )

    yield {
        "number": pr.number,
        "head_commit_id": commit_id,
        "base_ref": param["base_ref"],
        "head_ref": param["head_ref"],
    }

    log.info(f"Removing PR head ref branch: {param['head_ref']}")
    head_ref.delete()

    log.info(f"Closing PR: #{pr.number}")
    try:
        pr.edit(state="closed")
    except Exception:
        log.info("PR is merged or already closed")
