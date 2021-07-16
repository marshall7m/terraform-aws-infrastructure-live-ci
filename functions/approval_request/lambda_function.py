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
    target_email_addresses = event['payload']['TargetEmailAddresses']
    
    approval = s3.get_object(
        Bucket=os.environ['approval_bucket_name'],
        Key=os.environ['approval_bucket_key']
    )['Body'].read().decode()

    approval[task_token]['count'] = approval[task_token]['count'] + 1
    approval_count = approval[task_token]['count']
    approval_required = approval[task_token]['required']

    log.debug(f'Approval count: {approval_count}')
    log.debug(f'Approval count requirement: {approval_required}')

    
    raw_msg =f"""
    MIME-Version: 1.0
    Content-Type: text/html

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
    destination = ['To:' + email for email in target_email_addresses.split(',')]
    ses.send_raw_email(
        Source=os.environ['SENDER_EMAIL_ADDRESS'],
        Destinations = destination,
        RawMessage=raw_msg
    )

class ClientException(error):
    pass