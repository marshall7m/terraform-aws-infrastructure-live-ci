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

    log.info(f'Lambda Event: {event}')

    task_token = event['payload']['TaskToken']
    state_machine = event['payload']['StateMachine']
    execution_name = event['payload']['ExecutionName']
    account = event['payload']['Account']
    path = event['payload']['Path']
    
    approval_mapping = json.loads(s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=os.environ['APPROVAL_MAPPING_S3_KEY']
    )['Body'].read().decode())

    log.debug(f'Approval Mapping: {approval_mapping}')

    email_addresses = approval_mapping[account]['approval_emails']
    log.debug(f'Email Recipents: {email_addresses}')

    path_item = {
        'Approval': {
            'Required': approval_mapping[account]['approval_count_required'],
            'Count': 0,
            'Voters': []
        },
        'Rejection': {
            'Required': approval_mapping[account]['rejection_count_required'],
            'Count': 0,
            'Voters': []
        },
        'AwaitingApprovals': email_addresses,
        'TaskToken': task_token
    }
    log.debug(f'Path Item: {path_item}')

    execution = json.loads(s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
    )['Body'].read().decode())
    log.debug(f'Current Execution Data: {execution}')

    execution[account]['Deployments'][path] = path_item
    log.debug(f'Updated Execution Data: {execution}')

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
        Body=json.dumps(execution)
    )

    full_approval_api = f'{os.environ["APPROVAL_API"]}?ex={execution_name}&sm={state_machine}&taskToken={task_token}&account={account}&path={path}'
    log.debug(f'API Full URL: {full_approval_api}')

    destinations = []
    for email in email_addresses:
        destinations.append(
            {
                'Destination': {
                    'ToAddresses': [
                        email
                    ]
                },
                'ReplacementTemplateData': json.dumps({
                    'email_address': email
                })
            }
        )

    try:
        response = ses.send_bulk_templated_email(
            Template=os.environ['SES_TEMPLATE'],
            Source=os.environ['SENDER_EMAIL_ADDRESS'],
            DefaultTemplateData=json.dumps({
                "full_approval_api": full_approval_api, 
                "path": path
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