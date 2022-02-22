import boto3
import logging
import json
import os
from botocore.exceptions import ClientError
import subprocess


s3 = boto3.client('s3')
log = logging.getLogger(__name__)

def lambda_handler(event, context):
    """
    Reads AWS SES approval request from testing S3 bucket and pings
    the approval or denied URL based on the env var: $ACTION
    """
    
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.debug(f'Lambda Event: {event}')

    obj = s3.get_object(Bucket=os.environ['TESTING_BUCKET_NAME'], Key=os.environ['TESTING_EMAIL_S3_KEY'])

    log.debug(f'Object:\n{obj}')

    action_url = json.loads(obj['Body'].read())
    log.debug(f'Action URL: {action_url}')
    
    response = subprocess.run(["ping", "-c", action_url], capture_output=True, check=True)

    return response
