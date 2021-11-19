import os
import pytest
import logging
from psycopg2 import sql
import git
import os

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

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

def toggle_testing_trigger(cur, table, trigger, enable=False):
    log.info('Creating triggers for table')
    cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/testing_triggers.sql').read())

    if enable:
        cur.execute(sql.SQL("""
            DO $$
                BEGIN
                    ALTER TABLE {tbl} ENABLE TRIGGER {trigger};
                END;
            $$ LANGUAGE plpgsql;
        """).format(
            tbl=sql.Identifier(table),
            trigger=sql.Identifier(trigger)
        ))
    else:
        cur.execute(sql.SQL("""
            DO $$
                BEGIN
                    ALTER TABLE {tbl} DISABLE TRIGGER {trigger};
                END;
            $$ LANGUAGE plpgsql;
        """).format(
            tbl=sql.Identifier(table),
            trigger=sql.Identifier(trigger)
        ))

def mock_table(cur, conn, table, records, enable_defaults=False, update_parents=False):
    cols = records.keys()

    if type(records) == dict:
        records = [records]
    records = [tuple(r.values()) for r in records]

    if enable_defaults:
        toggle_testing_trigger(cur, table, f'{table}_default', enable=True)

    if update_parents:
        toggle_testing_trigger(cur, table, f'{table}_update_parents', enable=True)

    log.info('Inserting record(s)')
    log.info(records)
    query = sql.SQL('INSERT INTO {tbl} ({fields}) VALUES({values}) RETURNING *').format(
        tbl=sql.Identifier(table),
        fields=sql.SQL(', ').join(map(sql.Identifier, cols)),
        values=sql.SQL(', ').join(sql.Placeholder() * len(cols))
    )

    log.debug(f'Running: {query.as_string(conn)}')
    
    results = []
    for record in records:
        cur.execute(query, record)
        results.append(cur.fetchone())

    if enable_defaults:
        toggle_testing_trigger(cur, table, f'{table}_default', enable=False)
        
    if update_parents:
        toggle_testing_trigger(cur, table, f'{table}_update_parents', enable=False)

    return results



