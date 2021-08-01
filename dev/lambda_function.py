from collections import deque
import boto3
import logging
import json
import os

s3 = boto3.client('s3')
log = logging.getLogger(__name__)

def lambda_handler(event, context):
    """
    Updates account-level stack and returns lists of parallel directories
    to pass to step function deployment map
    """
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)
    
    log.info(event)
    execution_name = event['payload']['ExecutionName']

    execution = json.loads(s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
    )['Body'].read().decode())
    log.debug(f'Current Execution Data: {execution}')

    account_peek, _ = pop_stack(execution['AccountStack'])
    
    
    deploy_stack = []
    for account in account_peek:
        account_deploy_peek, account_deploy_stack = pop_stack(execution[account])
        execution['Accounts'][account]['Stack'] = deploy_stack
        deploy_stack.extend(account_deploy_peek)

        # if account contains no more path to deploy, remove from account stack
        if len(account_deploy_peek) == 0:
            del execution['AccountStack'][account]

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
        Body=json.dumps(execution)
    )

    return deploy_stack

def pop_stack(stack):
    """
    Returns tuple of keys from `stack` dictionary that have an empty list for it's value 
    and removes those keys from the `stack` dictionary's keys and values
    """

    peek = [ key for key, value in stack.items() if len(value) == 0 ]
    updated_stack = { key: [value for value in value_list if value not in peek] for key, value_list in stack.items() if key not in peek }

    return peek, updated_stack