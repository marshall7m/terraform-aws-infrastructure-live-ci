import boto3
import logging
import json
import os
import psycopg2
import psycopg2.extras
from psycopg2 import sql
from pprint import pformat

def lambda_handler(event, context):

    sf = boto3.client('stepfunctions')
    ssm = boto3.client('ssm')
    
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.info(event)

    action = event['body']['action']

    try:
        log.info('Connecting to metadb')
        conn = psycopg2.connect(password=ssm.get_parameter(Name=os.environ['PGPASSWORD_SSM_KEY'], WithDecryption=True)['Parameter']['Value'])
        conn.set_session(autocommit=True)
    except (Exception, psycopg2.DatabaseError) as e:
        log.error(e)
        return {
            'statusCode': 500,
            'message': 'Error while connecting to PostgreSQL'
        }

    try:
        log.info('Updating vote count')
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            with open(f'{os.path.dirname(os.path.realpath(__file__))}/update_vote.sql', 'r') as f:
                cur.execute(sql.SQL(f.read()).format(
                    action=sql.Literal(action),
                    recipient=sql.Literal(event['body']['recipient']),
                    execution_id=sql.Literal(event['query']['ex'])
                ))
                record = dict(cur.fetchone())
        log.debug(f'Record:\n{pformat(record)}')
        
        if record['status'] == 'aborted':
            log.info('Execution has been aborted')
            return {
                'statusCode': 410,
                'message': 'Execution has been aborted -- Approval submissions are not available anymore'
            }
        elif len(record['approval_voters']) == record['min_approval_count'] or len(record['rejection_voters']) == record['min_rejection_count']:
            log.info('Voter count meets requirement')

            log.info('Sending task token to Step Function Machine')
            sf.send_task_success(taskToken=event['query']['taskToken'], output=json.dumps({'Status': action}))
            return {
                'statusCode': 302,
                'message': 'Your choice has been submitted'
            }
        else:
            return {
                'statusCode': 302,
                'message': 'Your choice has been submitted'
            }
    except Exception as e:
        log.error(e)
        return {
            'statusCode': 500,
            'message': 'Error while processing approval action'
        }
    finally:
        if conn:
            log.info("Closing PostgreSQL connection")
            conn.close()