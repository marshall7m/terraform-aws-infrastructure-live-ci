import boto3
import logging
import json
import os
from botocore.exceptions import ClientError

s3 = boto3.client('s3')
ses = boto3.client('ses')
log = logging.getLogger(__name__)

def lambda_handler(event, context):
    """Sends approval request email to email addresses asssociated with Terragrunt path."""
    
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.debug(f'Lambda Event: {event}')

    full_approval_api = event['ApprovalAPI']
    voters = event['Voters']
    path = event['Path']

    log.debug(f'Path: {path}')
    log.debug(f'API Full URL: {full_approval_api}')

    destinations = []

    # need to create a separate destination object for each address since only the target address is interpolated into message template
    for address in voters:
        destinations.append(
            {
                'Destination': {
                    'ToAddresses': [
                        address
                    ]
                },
                'ReplacementTemplateData': json.dumps({
                    'email_address': address
                })
            }
        )

    response = ses.send_bulk_templated_email(
        Template=os.environ['SES_TEMPLATE'],
        Source=os.environ['SENDER_EMAIL_ADDRESS'],
        DefaultTemplateData=json.dumps({
            'full_approval_api': full_approval_api,
            'path': path
        }),
        Destinations=destinations
    )
    log.debug(f'Response:\n{response}')
    for msg in response['Status']:
        if msg['Status'] == 'Success':
            log.info("Email was succesfully sent")
        else:
            log.error('Email was not sent')
            log.debug(f"Email Status:\n{msg}")
