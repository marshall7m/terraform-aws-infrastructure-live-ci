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

    log.info(event)
    log.info(context)

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

    execution = json.loads(s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_id}.json',
    )['Body'].read().decode())

    email_addresses = approval_mapping[account]['approval_emails']

    path_item = {
        'Path': path,
        'Count': 0,
        'Required': approval_mapping[account]['min_approval_count'],
        'AwaitingApprovals': email_addresses,
        'TaskToken': task_token
    }
    log.debug(f'Path Item: {path_item}')

    execution[account]['Deployments'].append(path_item)
    log.debug(f'Updated Execution Data: {execution}')

    full_approval_api = f'{os.environ["APPROVAL_API"]}?ex={execution_id}&sm={state_machine}&taskToken={task_token}'
    log.debug(f'API Full URL: {full_approval_api}')

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_id}.json',
        Body=json.dumps(execution)
    )

    BODY_TEXT = "Hello,\r\nPlease see the attached terraform plan and fill out the approval form."

    BODY_HTML = """\
    <form action="{full_approval_api}" method="post">
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

    msg = MIMEMultipart('mixed')

    msg['Subject'] = f'{state_machine} Approval for Path: {path}' 
    msg['From'] = os.environ['SENDER_EMAIL_ADDRESS'] 
    msg['To'] = ', '.join(email_addresses)

    msg_body = MIMEMultipart('alternative')

    # Encode the text and HTML
    textpart = MIMEText(BODY_TEXT.encode('utf-8'), 'plain', 'utf-8')
    htmlpart = MIMEText(BODY_HTML.encode('utf-8'), 'html', 'utf-8')

    # Add the text and HTML
    msg_body.attach(textpart)
    msg_body.attach(htmlpart)

    ATTACHMENT = "lambda_function.py"
    # Encode attachment
    att = MIMEApplication(open(ATTACHMENT, 'rb').read())

    # Label type as attachment
    att.add_header('Content-Disposition','attachment',filename=os.path.basename(ATTACHMENT))
    msg.attach(msg_body)
    msg.attach(att)
    
    try:
        response = ses.send_raw_email(
            Source=os.environ['SENDER_EMAIL_ADDRESS'],
            Destinations=email_addresses,
            RawMessage={
                'Data': msg.as_string()
            }
        )
    except ClientError as e:
        print(e.response['Error']['Message'])
    else:
        print("Email was succesfully sent")
        print(f"Message ID: {response['MessageId']}")