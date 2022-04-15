import pytest
import unittest
import os
import logging
import sys
import json
from unittest.mock import patch
from pprint import pformat
from tests.helpers.utils import SetupUnit
from psycopg2 import sql

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

@pytest.mark.usefixtures('mock_conn', 'aws_credentials')

def run_lambda(event=None, context=None):
    '''Imports Lambda function after boto3 client patch has been created to prevent boto3 region_name not specified error'''
    from functions.approval_request.lambda_function import lambda_handler
    return lambda_handler(event, context)

@pytest.mark.parametrize('event,response,expected_status_code', [
    pytest.param(
        {
            'ApprovalAPI': 'mock-api',
            'Voters': [],
            'Path': 'test/foo'
        },
        {
            'Status': [
                {
                    'Status': 'Success',
                    'Error': '',
                    'MessageId': 'msg-1'
                }
            ]
        },
        302,
        id='successful_request'
    ),
    pytest.param(
        {
            'ApprovalAPI': 'mock-api',
            'Voters': [],
            'Path': 'test/foo'
        },
        {
            'Status': [
                {
                    'Status': 'Success',
                    'Error': '',
                    'MessageId': 'msg-1'
                },
                {
                    'Status': 'Failed',
                    'Error': 'Failed',
                    'MessageId': 'msg-2'
                },
                {
                    'Status': 'MessageRejected',
                    'Error': 'Rejected',
                    'MessageId': 'msg-3'
                }
            ]
        },
        500,
        id='failed_request'
    )
])
@patch('functions.approval_request.lambda_function.ses')
@patch.dict(os.environ, {'SES_TEMPLATE': 'mock-temp', 'SENDER_EMAIL_ADDRESS': 'mock-sender'}, clear=True)
@pytest.mark.usefixtures('mock_conn', 'aws_credentials')
def test_lambda_handler(mock_client, event, response, expected_status_code):
    mock_client.send_bulk_templated_email.return_value = response
    
    log.info('Running Lambda Function')
    response = run_lambda(event, {})

    assert response['statusCode'] == expected_status_code

    mock_client.send_bulk_templated_email.assert_called_once()