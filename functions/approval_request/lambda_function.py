import boto3
import logging
import json
import os
from botocore.exceptions import ClientError
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication


s3 = boto3.client('s3')
ses = boto3.client('ses')
log = logging.getLogger(__name__)

def lambda_handler(event, context):

    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.info(f'Lambda Event: {event}')

    task_token = event['payload']['TaskToken']
    state_machine = event['payload']['StateMachine']
    execution_id = event['payload']['ExecutionId']
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
        Key=f'{execution_id}.json',
    )['Body'].read().decode())
    log.debug(f'Current Execution Data: {execution}')

    execution[account]['Deployments'][path] = path_item
    log.debug(f'Updated Execution Data: {execution}')

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_id}.json',
        Body=json.dumps(execution)
    )

    full_approval_api = f'{os.environ["APPROVAL_API"]}?ex={execution_id}&sm={state_machine}&taskToken={task_token}&account={account}&path={path}'
    log.debug(f'API Full URL: {full_approval_api}')

    CHARSET = "UTF-8"
    
    BODY_HTML = f"""\
<form action="{full_approval_api}" method="post">
<label for="action">Choose an action:</label>
<select name="action" id="action">
<option value="approve">Approve</option>
<option value="reject">Reject</option>
</select>
<textarea name="comments" id="comments" style="width:96%;height:90px;background-color:lightgrey;color:black;border:none;padding:2%;font:14px/30px sans-serif;">
Reasoning for action
</textarea>
<input type="submit" value="Submit" style="background-color:red;color:white;padding:5px;font-size:18px;border:none;padding:8px;">
</form>
    """
    log.debug('HTML body:')
    log.debug(BODY_HTML)

    try:
        response = ses.send_email(
            Destination={
                'ToAddresses': email_addresses,
            },
            Message={
                'Body': {
                    'Html': {
                        'Charset': CHARSET,
                        'Data': BODY_HTML,
                    }
                },
                'Subject': {
                    'Charset': CHARSET,
                    'Data': f'',
                },
            },
            Source=os.environ['SENDER_EMAIL_ADDRESS']
        )
    except ClientError as e:
        print(e.response['Error']['Message'])
    else:
        print("Email was succesfully sent")
        print(f"Message ID: {response['MessageId']}")