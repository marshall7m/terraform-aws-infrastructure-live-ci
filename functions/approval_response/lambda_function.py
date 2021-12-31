import boto3
import logging
import json
import os
import psycopg2
import psycopg2.extras
from psycopg2 import sql

def lambda_handler(event, context):

    sf = boto3.client('stepfunctions')
    log = logging.getLogger(__name__)

    log.setLevel(logging.DEBUG)

    log.info(event)

    action = event['body']['action']

    try:
        session = boto3.Session(profile_name='RDSCreds')
        rds = session.client('rds')
        token = rds.generate_db_auth_token(DBHostname=os.environ["PGHOST"], Port=os.environ["PGPORT"], DBUsername=os.environ["PGUSER"], Region=os.environ["AWS_REGION"])

        conn = psycopg2.connect(
            user=os.environ["PGUSER"],
            password=token,
            host=os.environ["PGHOST"],
            port=os.environ["PGPORT"],
            database=os.environ["PGDATABASE"]
        )
        conn.set_session(autocommit=True)

        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursorNamedTupleCursor) as cur:
                with open(f'{os.path.dirname(os.path.realpath(__file__))}/update_vote.sql', 'r') as f:
                    cur.execute(sql.SQL(f.read()).format(
                        action=sql.Literal(action),
                        recipient=sql.Literal(event['body']['recipient']),
                        execution_id=sql.Literal(event['query']['ex'])
                    ))
                    record = dict(cur.fetchone())

            if record['status'] == 'aborted':
                log.info('Execution has been aborted -')
                return {
                    'statusCode': 410,
                    'message': 'Execution has been aborted -- Approval submissions are not available anymore'
                }
            elif record['approval_count'] == record['min_approval_count'] or record['rejection_count'] == record['min_rejection_count']:
                log.info('Voter count meets requirement')

                log.info('Sending task token to Step Function Machine')
                sf.send_task_success(taskToken=event['query']['taskToken'], output=json.dumps({'Status': action}))
                return {
                    'statusCode': 302,
                    'message': 'Your choice has been submitted'
                }
        except Exception:
            return {
                'statusCode': 500,
                'message': 'Error while processing approval action'
            }
    except (Exception, psycopg2.DatabaseError):
        return {
            'statusCode': 500,
            'message': 'Error while connecting to PostgreSQL'
        }
    finally:
        if conn:
            log.info("Closing PostgreSQL connection")
            conn.close()