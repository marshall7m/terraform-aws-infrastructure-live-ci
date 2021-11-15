import boto3
import logging
import json
import os
import psycopg2
import psycopg2.extras

def lambda_handler(event, context):

    sf = boto3.client('stepfunctions')
    log = logging.getLogger(__name__)

    log.setLevel(logging.DEBUG)

    log.info(event)

    action = event['body']['action']
    recipient = event['body']['recipient']

    task_token = event['query']['taskToken']
    execution_id = event['query']['ex']

    conn = None
    response = None

    try:
        conn = psycopg2.connect(
            user=os.environ["PGUSER"],
            password=os.environ["PGPASSWORD"],
            host=os.environ["PGHOST"],
            port=os.environ["PGPORT"],
            database=os.environ["PGDATABASE"]
        )

        cur = conn.cursor(cursor_factory = psycopg2.extras.NamedTupleCursor)

        try:
            record = cur.execute('update_vote.sql', (action, recipient, execution_id))
            response = {
                'statusCode': 302,
                'message': 'Your choice has been submitted'
            }
        except Exception as err:
            log.error('Error running update query')
            response = {
                'statusCode': err,
                'message': err
            }

        if record['approval_count'] == record['min_approval_count'] or record['rejection_count'] == record['min_rejection_count']:
            log.info('Voter count meets requirement')

            log.info('Sending task token to Step Function Machine')
            sf.send_task_success(taskToken=task_token, output=json.dumps({'Status': action}))
    except (Exception, psycopg2.DatabaseError) as error:
        print("Error while connecting to PostgreSQL", error)
    finally:
        if conn:
            log.info("Closing PostgreSQL connection")
            cur.close()
            conn.close()
    
    return response