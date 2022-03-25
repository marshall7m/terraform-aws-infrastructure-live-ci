import boto3
import logging
import json
import os
import requests
import sys
from pprint import pformat

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
ssm = boto3.client('ssm')

def lambda_handler(event, context):
    '''Creates a PR commit status that shows the current merge lock status'''

    log.debug(f'Event:\n{pformat(event)}')

    payload = json.loads(event['requestPayload']['body'])

    merge_lock = ssm.get_parameter(Name=os.environ['MERGE_LOCK_SSM_KEY'])['Parameter']['Value']
    token = ssm.get_parameter(Name=os.environ['GITHUB_TOKEN_SSM_KEY'], WithDecryption=True)['Parameter']['Value']
    commit_id = payload['pull_request']['head']['sha']
    repo_full_name = payload['repository']['full_name']

    log.info(f'Commit ID: {commit_id}')
    log.info(f'Repo: {repo_full_name}')
    log.info(f'Merge lock value: {merge_lock}')

    approval_url = f'https://{token}:x-oauth-basic@api.github.com/repos/{repo_full_name}/statuses/{commit_id}'
    
    if merge_lock != 'none':
        data = {
            'state': 'pending', 
            'description': f'Merging Terragrunt changes is locked. Integration is running for PR #{merge_lock}'
        }
    elif merge_lock == 'none':
        data = {
            'state': 'success',
            'description': 'Merging infrastructure changes are unlocked'
        }
    else:
        log.error(f'Invalid merge lock value: {merge_lock}')
        sys.exit(1)

    log.debug(f'Response Data:\n{data}')

    log.info('Sending response')
    response = requests.post(approval_url, json=data)
    log.debug(f'Response:\n{response}')