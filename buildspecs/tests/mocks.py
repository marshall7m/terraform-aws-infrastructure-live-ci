from pathlib import Path
import git
import pytest
import os
import subprocess
import logging
import shutil

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="session", autouse=True)
def session_repo_dir(tmpdir_factory):
    dir = tmpdir_factory.mktemp('test-repo')
    git.Repo.clone_from('https://github.com/marshall7m/infrastructure-live-testing-template.git', dir)

    return dir

@pytest.fixture(scope="function", autouse=True)
def function_repo_dir(session_repo_dir, tmp_path):
    dir = tmp_path / 'test-repo'
    dir.mkdir()
    git.Repo.clone_from(session_repo_dir, dir)

    return dir

@pytest.fixture(scope="session", autouse=True)
def apply_session_mock_repo(session_repo_dir):
    os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'] = f'{session_repo_dir}/tf-state'
    cmd = f'terragrunt run-all apply --terragrunt-working-dir {session_repo_dir}/directory_dependency/dev-account --terragrunt-non-interactive -auto-approve'.split(' ')
    
    log.debug(f'Command: {cmd}')
    subprocess.run(cmd, capture_output=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

@pytest.fixture(scope="session", autouse=True)
def destroy_session_mock_repo(session_repo_dir):
    cmd = f'terragrunt run-all destroy --terragrunt-working-dir {session_repo_dir}/directory_dependency/dev-account --terragrunt-non-interactive -auto-approve'.split(' ')

    log.debug(f'Command: {cmd}')
    subprocess.run(cmd, capture_output=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def create_test_function_tf_state(tmp_dir):
    test_case_tf_state_parent_dir = tmp_dir.mkdir('tf-state')
    
    os.chdir(os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'])
    for path in Path('.').rglob('*.tfstate'):
        new_path = os.path.join('../doo', path)
        os.makedirs(os.path.dirname(new_path))
        shutil.copy(path, new_path)

    # changing TESTING_LOCAL_PARENT_TF_STATE_DIR to test case tf-state dir to create persistant local tf-state
    # prevents loss of local tf-state when new github branches are created/checked out for mocking commits
    os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'] = test_case_tf_state_parent_dir

def setup_terragrunt_branch_tracking():
    pass

def teardown_tf_state():
    pass

@pytest.fixture(scope="function", autouse=True)
def teardown_function(cur, conn):
    cur.execute(open('fixtures/clear_metadb_tables.sql', 'r').read())
    cur.execute("""
    DO $$
        DECLARE
            _tbl VARCHAR;
            clear_tables TEXT[] := ARRAY['executions', 'account_dim', 'commit_queue', 'pr_queue'];
            reset_tables TEXT[] := ARRAY['pr_queue', 'commit_queue'];
        BEGIN
            FOREACH _tbl IN ARRAY clear_tables LOOP
                PERFORM truncate_if_exists(%(schema)s, %(catalog)s, _tbl);
            END LOOP;

            FOREACH _tbl IN ARRAY reset_tables LOOP
                PERFORM truncate_if_exists(%(schema)s, %(catalog)s, _tbl);
            END LOOP;
        END
    $$ LANGUAGE plpgsql;
    """, {'schema': 'public', 'catalog': conn.info.dbname})


def mock_commit(function_repo_dir, commit_items):
    pass

def mock_cloudwatch_execution( finished_status):

    return finished_status

def mock_tables(table, records, enable_defaults=True):
    pass

