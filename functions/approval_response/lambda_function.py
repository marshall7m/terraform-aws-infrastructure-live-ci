import boto3
import logging
import json
import os

s3 = boto3.client('s3')
sf = boto3.client('stepfunctions')
log = logging.getLogger(__name__)

def lambda_handler(event, context):

    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.info(event)
    log.info(context)
    return
    action = event['body']['action']
    task_token = event['query']['taskToken']
    state_machine = event['query']['sm']
    execution = event['query']['ex']

    if action == 'approve':
        msg = {'Status': 'Approve'}
    elif action == 'reject':
        msg = {'Status': 'Reject'}
    else:
        log.error('Unrecognized action. Expected: approve, reject.')
        raise {"Status": "Failed to process the request. Unrecognized Action."}
    
    approval = s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=execution
    )['Body'].read().decode()

    approval[task_token]['count'] = approval[task_token]['count'] + 1
    approval_count = approval[task_token]['count']
    approval_required = approval[task_token]['required']

    log.debug(f'Approval count: {approval_count}')
    log.debug(f'Approval count requirement: {approval_required}')

    if approval[task_token]['count'] == approval_required:
        log.info('Approval count met requirement')
        log.info('Sending task token to Step Function Machine')

        sf.send_task_success(
            taskToken=task_token,
            output=json.load(msg)
        )

        log.info('Deleting Task Token from approval map')
        del approval[task_token]

    s3.put_object(
            ACL='private',
            Body=approval,
            Bucket=os.environ['ARTIFACT_BUCKET_NAME']
        )

    lambda_arn = context['invokedFunctionArn'].split(':')

    url = f'https://console.aws.amazon.com/states/home?region={lambda_arn[3]}#/executions/details/arn:aws:states:{lambda_arn[3]}:{lambda_arn[4]}:execution:{state_machine}:{execution}'

    log.info(f'URL: {url}')
    response = {
        'statusCode': 302,
        'headers': {
            'Location': url
        }
    }
    
    return response