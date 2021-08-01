import boto3
import logging
import json
import os

s3 = boto3.client('s3')
sf = boto3.client('stepfunctions')
log = logging.getLogger(__name__)

def lambda_handler(event, context):

    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.info(event)

    action = event['body']['action']
    comments = event['body']['comments']
    recipient = event['body']['recipient']

    task_token = event['query']['taskToken']
    state_machine = event['query']['sm']
    execution_name = event['query']['ex']
    account = event['query']['account']
    path = event['query']['path']

    execution = json.loads(s3.get_object(
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
    )['Body'].read().decode())
    log.debug(f'Current Execution Data: {execution}')
    
    approval_voters = execution[account]['Deployments'][path]['Approval']['Voters']
    rejection_voters = execution[account]['Deployments'][path]['Rejection']['Voters']

    if action == 'approve':
        while recipient in rejection_voters:
            log.info('Removing {recipient} from Rejection Voters')
            execution[account]['Deployments'][path]['Rejection']['Voters'].remove(recipient)
        if recipient not in execution[account]['Deployments'][path]['Approval']['Voters']:
            msg = {'Status': 'Approve'}
            execution[account]['Deployments'][path]['Approval']['Count'] = execution[account]['Deployments'][path]['Approval']['Count'] + 1
            execution[account]['Deployments'][path]['Approval']['Voters'].append(recipient)
        else:
            log.info('Choice was resubmitted')
            response = {
                'statusCode': 302,
                'message': 'Your choice was already submitted'
            }
            return response
    elif action == 'reject':
        while recipient in approval_voters:
            log.info('Removing {recipient} from Approval Voters')
            execution[account]['Deployments'][path]['Approval']['Voters'].remove(recipient)
        if recipient not in execution[account]['Deployments'][path]['Rejection']['Voters']:
            msg = {'Status': 'Reject'}
            execution[account]['Deployments'][path]['Rejection']['Count'] = execution[account]['Deployments'][path]['Rejection']['Count'] + 1
            execution[account]['Deployments'][path]['Rejection']['Voters'].append(recipient)
        else:
            log.info('Choice was already resubmitted')
            response = {
                'statusCode': 302,
                'message': 'Your choice was already submitted'
            }
            return response
    else:
        log.error('Unrecognized action. Expected: approve, reject.')
        raise {"Status": "Failed to process the request. Unrecognized Action."}
    
    log.debug(f'Updated Execution Data: {execution}')

    approval_count = execution[account]['Deployments'][path]['Approval']['Count']
    approval_count_required = execution[account]['Deployments'][path]['Approval']['Required']

    log.debug(f'Approval count: {approval_count}')
    log.debug(f'Approval count requirement: {approval_count_required}')
    
    rejection_count = execution[account]['Deployments'][path]['Rejection']['Count']
    rejection_count_required = execution[account]['Deployments'][path]['Rejection']['Required']

    log.debug(f'Rejection count: {rejection_count}')
    log.debug(f'Rejection count requirement: {rejection_count_required}')

    if approval_count == approval_count_required:
        log.info('Approval count meets requirement')
        log.info('Sending task token to Step Function Machine')

        log.info('Marking Step Function task as successful')
        sf.send_task_success(
            taskToken=task_token,
            output=json.dumps(msg)
        )
    elif rejection_count == rejection_count_required:
        log.info('Rejection count meets requirement')
        log.info('Sending task token to Step Function Machine')

        log.info('Marking Step Function task as failure')
        sf.send_task_success(
            taskToken=task_token,
            output=json.dumps(msg)
        )
    else:
        log.info(f'Awaiting approval from {approval_count_required - approval_count} approvers')
        log.info(f'Rejection from {rejection_count_required - rejection_count} approvers to trigger rollback')

    s3.put_object(
        ACL='private',
        Bucket=os.environ['ARTIFACT_BUCKET_NAME'],
        Key=f'{execution_name}.json',
        Body=json.dumps(execution)
    )

    response = {
        'statusCode': 302,
        'message': 'Your choice has been submitted'
    }
    
    return response

    #instead of comments within email:
    #redirect to PR terraform file where reviewer can leave feedback if rejected
    # have comment have preset filepath (e.g. filepath: x/)
    # if reject:
    # github: request changes with feedback from comment box
    # if approve:
    # github: comment with feedback from comment box

    # PR file link
    # Codebuild plan