import boto3
import logging
import json
import os
from botocore.exceptions import ClientError

s3 = boto3.client('s3')
ses = boto3.client('ses')
log = logging.getLogger(__name__)

def lambda_handler(event, context):
    """
    Creates approval object for input path and uploads to S3 execution artifact. Sends approval request email to
    email addresses asssociated with path.

    Individual path approval objects are created here and not within the trigger step function CodeBuild project 
    to prevent unnecessary cluttering of the execution artifact and prevent any confusion on what paths are awaiting
    approval. 
    """
    
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.debug(f'Lambda Event: {event}')

    execution_name = event['payload']['ExecutionName']
    email_voters = event['payload']['EmailVoters']
    path_approval = event['payload']['PathApproval']
    full_approval_api = event['payload']['ApprovalAPI']


    log.debug(f'Path Approval: {path_approval}')

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
        Body=json.dumps(path_approval)
    )

    log.debug(f'API Full URL: {full_approval_api}')

    destinations = []
    for address in email_voters:
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

    try:
        response = ses.send_bulk_templated_email(
            Template=os.environ['SES_TEMPLATE'],
            Source=os.environ['SENDER_EMAIL_ADDRESS'],
            DefaultTemplateData=json.dumps({
                "full_approval_api": full_approval_api
            }),
            Destinations=destinations
        )
    except ClientError as e:
        print(e.response['Error']['Message'])
    else:
        
        for msg in response['Status']:
            if msg['Status'] == 'Success':
                print("Email was succesfully sent")
                print(f"Message ID: {msg['MessageId']}\n")
            else:
                print("Email was not sent")
                print(f"Message ID: {msg['MessageId']}")
                print(f"Status: {msg['Status']}")
                print(f"Error: {msg['Error']}\n")