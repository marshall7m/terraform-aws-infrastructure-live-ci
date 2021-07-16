import boto3
import logging
import json
import os


s3 = boto3.client('s3')
ses = boto3.client('ses')
log = logging.getLogger(__name__)

def lambda_handler(event, context):

    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.info(event)
    log.info(context)

    task_token = event['payload']['TaskToken']
    state_machine = event['payload']['StateMachine']
    execution = event['payload']['ExecutionId']
    account = event['payload']['Account']
    path = event['payload']['Path']

    execution_data = s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=execution
    )['Body'].read().decode()

    path_item = {
        'Path': path
        'Count': 0,
        'Required': len(approval_emails),
        'AwaitingApprovals': approval_emails,
        'TaskToken': task_token
    }
    
    approval_item = approval[account]['Deployments'].append(path_item)

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=execution
        Body=approval_item
    )
    
    raw_msg =f"""
    MIME-Version: 1.0k
    Content-Type: text/html
    Subject: {state_machine} Approval for Path: {path}

    <!DOCTYPE html>
    <title>Approval Request</title>

    <form action="{os.environ['APPROVAL_API']}" method="post">
    <label for="action">Choose an action:</label>
    <select name="action" id="action">
    <option value="accept">Accept</option>
    <option value="decline">Decline</option>
    </select>
    <textarea name="comments" id="comments" style="width:96%;height:90px;background-color:lightgrey;color:black;border:none;padding:2%;font:14px/30px sans-serif;">
    Reasoning for action
    </textarea>
    <input type="submit" value="Submit" style="background-color:red;color:white;padding:5px;font-size:18px;border:none;padding:8px;">
    </form>
    """ 
    ses.send_raw_email(
        Source=os.environ['SENDER_EMAIL_ADDRESS'],
        Destinations = ['To:' + email for email in approval_emails],
        RawMessage=raw_msg
    )

class ClientException(error):
    pass