import git
import pytest
from github import Github
import os
from psycopg2 import sql
from psycopg2.errors import AssertFailure
import psycopg2
import psycopg2.extras
import subprocess
import random
import string
import inspect
import json
import pandas
import pandas.io.sql as psql

import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class AssertionFailures(Exception):
    pass

class TestSetup:
    assertions = []
    def __init__(self, conn, git_url, git_dir, gh_token, remote_changes=False):
        self.remote_changes = remote_changes
        self.conn = conn
        self.conn.set_session(autocommit=True)

        self.git_url = git_url
        self.git_dir = str(git_dir)
        self.gh_repo_full_name = '/'.join(self.git_url.split('.git')[0].split('/')[-2:]) 
        self.gh = Github(login_or_token=gh_token)
        self.gh_token = gh_token
        self.gh_repo = self.gh.get_repo(self.gh_repo_full_name)
        self.git_repo = git.Repo(self.git_dir)
        self.user = self.gh.get_user()
        self.remote = self.create_fork_remote()

        self.init_sql_utils()

    def __enter__(self):
        return self

    def __exit__(self, *args, **kwargs):
        log.debug('Closing metadb connection')
        self.conn.close()

    def get_base_commit_id(self):
        return str(git.repo.fun.rev_parse(self.git_repo, os.environ['BASE_REF']))

    def init_sql_utils(self):
        cur = self.conn.cursor()
        log.debug('Creating postgres utility functions')
        files = [f'{os.path.dirname(os.path.realpath(__file__))}/../buildspecs/sql/utils.sql']

        for file in files:
            log.debug(f'File: {file}')
            with open(file, 'r') as f:
                cur.execute(f.read())

    def create_fork_remote(self):
        self.user.create_fork(self.gh_repo)
        print(f'git dir : {self.git_dir}')

        remotes = self.git_repo.remotes
        log.debug(f'Remotes: {remotes}')

        if self.remote_changes:
            new_remote = 'remote'
            if not git.remote.Remote(self.git_repo, new_remote).exists():
                self.remote = git.Repo.create_remote(self.git_repo, new_remote, f"https://{self.user.login}:{self.gh_token}@github.com/{self.gh_repo_full_name}.git")
        else:
            new_remote = 'local'
            if not git.remote.Remote(self.git_repo, new_remote).exists():
                self.remote = git.Repo.create_remote(self.git_repo, new_remote, self.git_dir)

        return self.remote

    @classmethod
    def toggle_trigger(cls, conn, table, trigger, enable=False):
        with conn.cursor() as cur:
            log.debug('Creating triggers for table')
            cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/testing_triggers.sql').read())

            cur.execute(sql.SQL("ALTER TABLE {tbl} {action} TRIGGER {trigger}").format(
                tbl=sql.Identifier(table),
                action=sql.SQL('ENABLE' if enable else 'DISABLE'),
                trigger=sql.Identifier(trigger)
            ))

            conn.commit()

    @classmethod
    def truncate_if_exists(cls, conn, schema, catalog, table):
        with conn.cursor() as cur:
            query = sql.SQL("""
            DO $$
                DECLARE 
                    _full_table TEXT := concat_ws('.', quote_ident({schema}), quote_ident({table}));
                BEGIN
                    IF EXISTS (
                        SELECT 1 
                        FROM  INFORMATION_SCHEMA.TABLES 
                        WHERE table_schema = {schema} 
                        AND table_catalog = {catalog} 
                        AND table_name = {table}
                    ) THEN
                        EXECUTE 'TRUNCATE ' || _full_table ;
                    END IF;
                END;
            $$ LANGUAGE plpgsql;
            """).format(
                schema=sql.Literal(schema),
                catalog=sql.Literal(catalog),
                table=sql.Literal(table)
            )
            log.debug(f'Query:\n{query.as_string(conn)}')
            cur.execute(query)

    @classmethod
    def create_records(cls, conn, table, records, enable_defaults=None, update_parents=None):
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            if type(records) == dict:
                records = [records]

            cols = set().union(*(r.keys() for r in records))

            results = []
            try:
                if enable_defaults != None:
                    cls.toggle_trigger(conn, table, f'{table}_default', enable=enable_defaults)
                
                if update_parents != None:
                    cls.toggle_trigger(conn, table, f'{table}_update_parents', enable=update_parents)

                for record in records:
                    cols = record.keys()

                    log.info('Inserting record(s)')
                    log.info(record)
                    query = sql.SQL('INSERT INTO {tbl} ({fields}) VALUES({values}) RETURNING *').format(
                        tbl=sql.Identifier(table),
                        fields=sql.SQL(', ').join(map(sql.Identifier, cols)),
                        values=sql.SQL(', ').join(map(sql.Placeholder, cols))
                    )

                    log.debug(f'Running: {query.as_string(conn)}')
                    
                    cur.execute(query, record)
                    conn.commit()

                    record = cur.fetchone()
                    results.append(dict(record))
            except Exception as e:
                log.error(e)
                raise
            finally:
                if enable_defaults != None:
                    cls.toggle_trigger(conn, table, f'{table}_default', enable=False)

                if update_parents != None:
                    cls.toggle_trigger(conn, table, f'{table}_update_parents', enable=False)

        return results

    def pr(self, base_ref, head_ref):
        return PR(base_ref, head_ref, **self.__dict__)

    def collect_record_assertion(self, table, conditions, debug_conditions=[], count=1):
        assertion = sql.SQL("""
        DO $$
            BEGIN
                ASSERT (
                    SELECT COUNT(*)
                    FROM {tbl}
                    WHERE
                    {cond}
                ) = {count};
            END;
        $$ LANGUAGE plpgsql;
        """).format(
            tbl=sql.Identifier(table),
            count=sql.Literal(count),
            cond=sql.SQL('\n\t\t\tAND ').join([sql.SQL(' = ').join(sql.Identifier(key) + sql.Literal(val)) for key,val in conditions.items()])
        ).as_string(self.conn)

        debug = []
        for conditions in debug_conditions:
            query = sql.SQL("""
            SELECT * 
            FROM {tbl} 
            WHERE 
            {cond}
            """).format(
                tbl=sql.Identifier(table),
                cond=sql.SQL('\n\t\tAND ').join([sql.SQL(' = ').join(sql.Identifier(key) + sql.Literal(val)) for key,val in conditions.items()])
            ).as_string(self.conn)
            
            debug.append(query)
        self.assertions.append({'assertion': assertion, 'debug': debug})

    def run_collected_assertions(self):
        count = 0
        total = len(self.assertions)
        with self.conn.cursor() as cur:
            for item in self.assertions:
                try:
                    cur.execute(item['assertion'])
                    self.conn.commit()
                    count += 1
                except psycopg2.errors.lookup("P0004"):
                    self.conn.rollback()
                    log.error('Assertion failed')
                    log.debug(f'Query:\n{item["assertion"]}')
                    with pandas.option_context('display.max_rows', None, 'display.max_columns', None):
                        
                        for query in item['debug']:
                            log.debug(f'Debug query:\n{query}')
                            log.debug(psql.read_sql(query, self.conn).T)
                            self.conn.commit()

        log.info(f'{count}/{total} assertions were successful')
        if count != total:
            raise AssertionFailures(f'{total-count} assertions failed')

    @classmethod
    def assert_record_count(cls, conn, table, conditions, count=1):

        query = sql.SQL("""
        DO $$
            BEGIN
                ASSERT (
                    SELECT COUNT(*)
                    FROM {tbl}
                    WHERE
                    {cond}
                ) = {count};
            END;
        $$ LANGUAGE plpgsql;
        """).format(
            tbl=sql.Identifier(table),
            count=sql.Literal(count),
            cond=sql.SQL('\n\t\t\tAND ').join([sql.SQL(' = ').join(sql.Identifier(key) + sql.Literal(val)) for key,val in conditions.items()])
        )

        log.debug(f'Query: {query.as_string(conn)}')

        with conn.cursor() as cur:
            try:
                cur.execute(query.as_string(conn))
                return True
            except AssertFailure:
                log.error('Assertion was not met')
                return False
class PR(TestSetup):
    def __init__(self, base_ref, head_ref, **kwargs):
        # self.test_setup = test_setup
        self.base_ref = base_ref
        self.head_ref = head_ref
        self.commit_ids = []
        for k in kwargs.keys():
          self.__setattr__(k, kwargs[k])

    def create_pr(self, title='TestPRSetup Test PR', body='None', **column_args):
        if self.remote_changes:
            return self.gh_repo.create_pull(title=title, body=body, head=self.head_ref, base=self.base_ref)
        else:
            log.info('remote_changes set to False -- skip creating remote PR')


    def create_commit_changes(self, apply_changes, create_provider_resource, cfg_path):
        abs_cfg_path = self.git_dir + '/' + cfg_path
        filename = ''.join(random.choice(string.ascii_lowercase) for _ in range(8))
        filepath = abs_cfg_path + '/' + filename + '.tf'

        if create_provider_resource:
            log.debug('Creating null provider resource config file')
            # for simplicity, assume null provider isn't in repo
            file_content = inspect.cleandoc("""
            provider "null" {}

            resource "null_resource" "this" {}
            """)
            
            res = {
                "type": "provider",
                "address": "registry.terraform.io/hashicorp/null",
                "content": file_content,
                "resource_spec": "null_resource.this"
            }

        else:
            log.debug('Creating random output file')

            value = 'test'
            file_content = inspect.cleandoc(f"""
            output "{filename}" {{
                value = "{value}"
            }}
            """)

            res = {
                "type": "output",
                "resource_spec": f'output.{filename}',
                "value": value,
                "file_path": filepath
            }
        
        with open(filepath, "w") as text_file:
            text_file.write(file_content)

        if apply_changes:
            subprocess.run(f'terragrunt apply --terragrunt-working-dir {cfg_path} -auto-approve'.split(' '), capture_output=False)
        
        log.debug(f'Adding file to commit: {filepath}')
        self.git_repo.index.add(filepath)

        return res

    def merge(self):
        log.info(f'Merging {self.head_ref} into {self.base_ref}')

        self.git_repo.git.checkout('-B', self.base_ref)
        self.git_repo.git.merge(self.head_ref)

        self.git_repo.git.switch('-')

    def create_commit(self, modify_items, commit_message='TestPRSetup.create_commit() test'):

        log.debug(f'Checking out branch: {self.head_ref}')
        self.git_repo.git.checkout('-B', self.head_ref)

        for idx, item in enumerate(modify_items):
            modify_items[idx].update(self.create_commit_changes(item['apply_changes'], item['create_provider_resource'], item['cfg_path']))
            if 'record' in item:
                modify_items[idx]['record'].update({'new_providers': [modify_items[idx]['address']]})

        commit_id = self.git_repo.index.commit(commit_message).hexsha
        self.commit_ids.append(commit_id)
        self.remote.push()

        for idx, item in enumerate(modify_items):
            if 'record' in item:
                modify_items[idx].update({'record': self.create_commit_record({**item['record'], **{'cfg_path': item['cfg_path'], 'commit_id': commit_id}})})
            elif 'record_assertion' in item:
                assertion = {}
                if 'new_provider_resources' in item['record_assertion']:
                    assertion['new_providers'] = [modify_items[idx]['address']]
                    assertion['new_resources'] = [modify_items[idx]['resource_spec']]
                if 'status' in item['record_assertion']:
                    assertion['status'] = item['record_assertion']['status']

                assertion = {**assertion, **{'cfg_path': item['cfg_path'], 'commit_id': commit_id}}
                self.collect_record_assertion('executions', assertion, )

        return modify_items
    def create_commit_record(self, cw_event_finished_status=None, **column_args):
        record = self.create_records(
                    self.conn, 
                    'executions', 
                    {**column_args, **{'base_ref': self.base_ref, 'head_ref': self.head_ref}}, 
                    enable_defaults=True
                )[0]

        if cw_event_finished_status != None:
            record = {**record, **{'status': cw_event_finished_status}}
            os.environ['EVENTBRIDGE_EVENT'] = json.dumps(record)
        
        return record

    def cleanup(self):
        log.debug('Closing PR')

        log.debug('Removing PR branch')

