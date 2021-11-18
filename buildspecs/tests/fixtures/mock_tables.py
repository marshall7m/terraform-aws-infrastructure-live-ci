import pytest
import logging
from psycopg2 import sql
import git

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="function", autouse=True)
def mock_cloudwatch_execution(mock_commit=True, finished_status):

    if mock_commit:

    return finished_status

@pytest.fixture
def mock_commit(function_repo_dir, commit_items, remote, target_branch, source_branch='master'):

    repo = git.Repo(function_repo_dir)
    sb = repo.get_branch(source_branch)
    repo.create_git_ref(ref='refs/heads/' + target_branch, sha=sb.commit.sha)

    file_list = create_changes()
    commit_message = ''
    repo.index.add(file_list)
    repo.index.commit(commit_message)
    remote.push()

def mock_table(cur, table, records, enable_defaults=False, update_parents=False):
    cols = records.keys()
    records = tuple(i for i in list(x))

    log.info('Enabling triggers for table')
    cur.execute(open('./fixtures/insert_mock_records.sql').read(), (enable=True))

    log.info('Inserting record(s)')
    sql = ''.format(
        table=sql.Identifier(table),
        fields=sql.SQL(', ').join(map(sql.Identifier, cols)),
        values=sql.SQL(', ').join(sql.Placeholder() * len(cols))),
        enable_defaults=sql.Literal(enable_defaults),
        update_parents=sql.Literal(update_parents)
    )

    log.debug(f'Running: {sql}')
    results = cur.execute(sql, records)

    cur.execute(open('./fixtures/insert_mock_records.sql').read(), (enable=False))
    yield results

    cur.execute(open('./fixtures/insert_mock_records.sql').read(), (enable=False))


