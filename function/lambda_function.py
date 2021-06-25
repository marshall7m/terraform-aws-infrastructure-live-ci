import boto3
import logging
import json

sf = boto3.client('stepfunctions')
log = logging.getLogger(__name__)

def lambda_handler(event, context):

    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.info(event)
    log.info(context)

    action = event['query']['action']
    task_token = event['query']['taskToken']
    state_machine = event['query']['sm']
    execution = event['query']['ex']

    if action == 'approve':
        msg = {'Status': 'Approve'}
    elif action == 'reject':
        msg = {'Status': 'Reject'}
    else:
        log.error('Unrecognized action. Expected: approve, reject.')
        raise ClientException({"Status": "Failed to process the request. Unrecognized Action."})
    
    sf.send_task_success(
        taskToken=task_token,
        output=json.load(msg)
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

class ClientException(error):
    pass