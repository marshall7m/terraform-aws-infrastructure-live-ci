import os
import sys
import logging
import json
import boto3
from pprint import pformat
import sys
import re
import aurora_data_api

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def execution_finished(cur, output):
    sf = boto3.client('stepfunctions')
    log.info('Updating execution record status')
    cur.execute(f"""
    UPDATE executions
    SET "status" = {output['status']}
    WHERE execution_id = {output['execution_id']}
    """)
    
    if not output['is_rollback'] and output['status'] == 'failed':
        log.info('Aborting all deployments for commit')
        cur.execute(f"""
        UPDATE executions
        SET "status" = 'aborted'
        WHERE "status" IN ('waiting', 'running')
        AND commit_id = {output['commit_id']}
        AND is_rollback = false
        RETURNING execution_id
        """)

        log.info('Aborting Step Function executions')
        results = cur.fetchall()
        log.debug(f'Results: {results}')
        if results != None:
            aborted_ids = [dict(r)['execution_id'] for r in results]

            for id in aborted_ids:
                try:
                    execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=os.environ["STATE_MACHINE_ARN"])['executions'] if execution['name'] == id][0]
                except IndexError:
                    log.debug(f'Step Function execution for execution ID does not exist: {id}')
                    continue
                log.debug(f'Execution ARN: {execution_arn}')
                
                sf.stop_execution(
                    executionArn=execution_arn,
                    error='DependencyError',
                    cause=f'cfg_path dependency failed: {output["cfg_path"]}'
                )

        log.info('Creating rollback executions if needed')
        with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_rollback_stack.sql', 'r') as f:
            cur.execute(f.read()).format(commit_id=output['commit_id'])
            results = cur.fetchall()
            log.debug(f'Results:\n{results}')
            if results != None:
                rollback_records = [dict(r) for r in results]
                log.debug(f'Rollback records:\n{pformat(rollback_records)}')
                
    elif output['is_rollback'] == True and output['status'] == 'failed':
        log.error("Rollback execution failed -- User with administrative privileges will need to manually fix configuration")
        sys.exit(1)
    
def start_sf_executions(cur):
    log.info('Getting executions that have all account dependencies and terragrunt dependencies met')
    sf = boto3.client('stepfunctions')
    try:
        with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/select_target_execution_ids.sql') as f:
            cur.execute(f.read())
    except aurora_data_api.exceptions.DatabaseError as e:
        log.error(f'Exception:\n{e}')
        if bool(re.search(r'SQLState:\s+?21000', e.__cause__.response['Error']['Message'])):
            ssm = boto3.client('ssm')
            log.error('More than one commit ID is waiting')
            log.error(f'Merge lock value: {ssm.get_parameter(Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"])["Parameter"]["Value"]}')
            cur.execute("""
            SELECT DISTINCT commit_id, is_rollback 
            FROM executions
            WHERE "status" = 'waiting'
            """)
            log.error(f'Waiting commits:\n{pformat(cur.fetchall())}')
            sys.exit(1)

    ids = cur.fetchone()
    if ids == None:
        log.info('No executions are ready')
        return
    else:
        target_execution_ids = [id for id in ids[0]]

    log.debug(f'IDs: {target_execution_ids}')
    log.info(f'Count: {len(target_execution_ids)}')

    if 'DRY_RUN' in os.environ:
        log.info('DRY_RUN was set -- skip starting sf executions')
    else:
        for id in target_execution_ids:
            log.info(f'Execution ID: {id}')
            
            log.debug('Updating execution status to running')
            cur.execute(f"""
                UPDATE executions
                SET status = 'running'
                WHERE execution_id = {id}
                RETURNING *
            """)

            sf_input = json.dumps(cur.fetchone())
            log.debug(f'SF input:\n{pformat(sf_input)}')

            log.debug('Starting sf execution')
            sf.start_execution(stateMachineArn=os.environ['STATE_MACHINE_ARN'], name=id, input=sf_input)

def lambda_handler(event, context):
    log.debug(f'Event:\n{pformat(event)}')
    ssm = boto3.client('ssm')
    with aurora_data_api.connect(
        aurora_cluster_arn=os.environ['METADB_CLUSTER_ARN'],
        secret_arn=os.environ['METADB_SECRET_ARN'],
        database=os.environ['METADB_NAME']
    ) as conn:
        with conn.cursor() as cur:
            if 'EXECUTION_OUTPUT' in os.environ:
                log.info('Triggered via Step Function Event')
                output = json.loads(os.environ['EXECUTION_OUTPUT'])
                log.debug(f'Parsed Step Function Output:\n{pformat(output)}')
                execution_finished(cur, output)

            log.info('Checking if commit executions are in progress')
            # TODO: use a select 1 query to only scan table until condition is met - or select distinct statuses from table and then see if waiting/running is found
            
            cur.execute("SELECT * FROM executions WHERE status IN ('waiting', 'running')")

            if cur.rowcount > 0:
                log.info('Starting Step Function Deployment Flow')
                start_sf_executions(cur)
            else:
                log.info('No executions are waiting or running -- unlocking merge action within target branch')
                ssm.put_parameter(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value='none', Type='String', Overwrite=True)
    
    