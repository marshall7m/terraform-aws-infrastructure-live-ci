import git
import pytest
from github import Github
import os
from psycopg2 import sql
import psycopg2
import psycopg2.extras
import subprocess
import random
import string
import inspect
import json

import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TestSetup:
    assertions = []
    def __init__(self, conn, git_url, git_dir, gh_token, remote_changes=False):
        self.remote_changes = remote_changes
        self.conn = conn
        self.git_url = git_url
        self.git_dir = str(git_dir)
        self.gh_repo_full_name = '/'.join(self.git_url.split('.git')[0].split('/')[-2:]) 
        self.gh = Github(login_or_token=gh_token)
        self.gh_token = gh_token
        self.gh_repo = self.gh.get_repo(self.gh_repo_full_name)
        self.git_repo = git.Repo(self.git_dir)
        self.user = self.gh.get_user()
        self.remote = self.create_fork_remote()

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
        cur = conn.cursor()

        log.debug('Creating trigger depedency functions if not created')
        cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/../buildspecs/sql/utils.sql').read())

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
 
    @classmethod
    def create_records(cls, conn, table, records, enable_defaults=False, update_parents=False):
        cur = conn.cursor(cursor_factory = psycopg2.extras.RealDictCursor)
                        
        if type(records) == dict:
            records = [records]

        cols = set().union(*(r.keys() for r in records))

        if enable_defaults:
            cls.toggle_trigger(conn, table, f'{table}_default', enable=True)

        if update_parents:
            cls.toggle_trigger(conn, table, f'{table}_update_parents', enable=True)

        results = []
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
            record = cur.fetchone()
            results.append(record)

        if enable_defaults:
            cls.toggle_trigger(conn, table, f'{table}_default', enable=False)
            
        if update_parents:
            cls.toggle_trigger(conn, table, f'{table}_update_parents', enable=False)

        return results

    def pr(self, base_ref, head_ref):
        return PR(base_ref, head_ref, **self.__dict__)

    def collect_record_assertion(self, table, conditions, count=1):
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

        self.assertions.append(query)

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

        cur = conn.cursor()

        try:
            cur.execute(query.as_string(conn))
            return True
        except Exception as e:
            print(e)
            return False


class PR(TestSetup):
    def __init__(self, base_ref, head_ref, *args, **kwargs):
        # self.test_setup = test_setup
        self.base_ref = base_ref
        self.head_ref = head_ref
        self.pr_record = {'head_ref': self.head_ref, 'base_ref': self.base_ref}
        self.commit_records = []
        self.execution_records = []
        self.head_branch = None
        self.cw_event = {}
        for k in kwargs.keys():
          self.__setattr__(k, kwargs[k])

    def create_pr(self, title='TestPRSetup Test PR', body='None', **column_args):
        if self.remote_changes:
            pr = self.gh_repo.create_pull(title=title, body=body, head=self.head_ref, base=self.base_ref)
            self.pr_record.update(**column_args, pr_id=pr.number)
        else:
            self.pr_record.update(**column_args)

    def create_commit_changes(self, modify_items):

        for idx, item in enumerate(modify_items):
            abs_cfg_path = self.git_dir + '/' + item['cfg_path']
            filename = ''.join(random.choice(string.ascii_lowercase) for _ in range(8))
            filepath = abs_cfg_path + '/' + filename + '.tf'

            if item['create_provider_resource']:
                log.debug('Creating null provider resource config file')
                # for simplicity, assume null provider isn't in repo
                file_content = inspect.cleandoc("""
                provider "null" {}

                resource "null_resource" "this" {}
                """)
                
                modify_items[idx].update({
                    "type": "provider",
                    "address": "registry.terraform.io/hashicorp/null",
                    "content": file_content,
                    "resource_spec": "null_resource.this"
                })
            else:
                log.debug('Creating random output file')

                value = 'test'
                file_content = inspect.cleandoc(f"""
                output "{filepath}" {{
                    value = "{value}"
                }}
                """)

                modify_items[idx].update({
                    "type": "output",
                    "resource_spec": f'output.{filename}',
                    "value": value,
                    "file_path": filepath
                })
            
            with open(filepath, "w") as text_file:
                text_file.write(file_content)

            if item['apply_changes']:
                subprocess.run(f'terragrunt apply --terragrunt-working-dir {item["cfg_path"]} -auto-approve'.split(' '), capture_output=False)
            
            log.debug(f'Adding file to commit: {filepath}')
            self.git_repo.index.add(filepath)

        return modify_items
    
    def create_commit(self, modify_items, commit_message='TestPRSetup().create_commit test', **column_args):

        log.debug(f'Checking out branch: {self.head_ref}')
        self.git_repo.git.checkout('-B', self.head_ref)

        modify_items = self.create_commit_changes(modify_items)

        commit_id = self.git_repo.index.commit(commit_message)

        if 'pr_id' in self.pr_record:
            column_args.update(pr_id=self.pr_record['pr_id'], commit_id=commit_id.hexsha)
        else:
            column_args.update(commit_id=commit_id.hexsha)
    
        self.commit_records.append(column_args)

        for item in modify_items:
            if 'execution' in item:
                # merges commit record with execution record except on status since commit status != execution status
                record = {**item['execution'], **{col: val for col,val in column_args.items() if col != 'status'}}
                self.create_execution(**record)

        self.remote.push()

        return modify_items

    def create_execution(self, is_cw_event, **column_args):
        if is_cw_event:
            self.cw_event = column_args
        else:
            self.execution_records.append(column_args)

    def insert_records(self):
    
        self.pr_record = self.create_records(self.conn, 'pr_queue', self.pr_record, enable_defaults=True)[0]
        self.commit_records = self.create_records(self.conn, 'commit_queue', self.commit_records, enable_defaults=True)
        self.execution_records = self.create_records(self.conn, 'executions', self.execution_records, enable_defaults=True)

        if self.cw_event:
            self.cw_event = self.create_records(self.conn, 'executions', self.cw_event, enable_defaults=True)[0]
            os.environ['EVENTBRIDGE_EVENT'] = json.dumps(self.cw_event)
