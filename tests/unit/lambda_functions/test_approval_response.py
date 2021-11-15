import pytest
import unittest
import os
from unittest.mock import patch
import psycopg2

from functions.approval_response.lambda_function import lambda_handler

class TestApprovalResponse(unittest.TestCase):

    def append_first(self):
        sf.send_task_success = unittest.MagicMock()
        return None

    @pytest.fixture(autouse=True)
    def append_first(self):
        os.environ["AWS_DEFAULT_REGION"] = "us-west-2"
        return None

    @pytest.fixture(autouse=True)
    def context(self):
        return {}

    @pytest.fixtures
    def event(self):
        return {
            "body": {
                "action": "approval",
                "recipient": "test-user"
            }
        }

    def create_mock_event(body):
        query = {
            "query": {
                "taskToken": "test-token",
                "ex": "run-001"
            }
        }
        return {**body, **query}

    @patch("lambda_handler.boto3.client")
    def test_valid_action(self, event, context):
        response = lambda _handler(event, context)
        expected = {
            'statusCode': 302,
            'message': 'Your choice has been submitted'
        }

        self.assertEqual(expected, response)

    # def test_reject_action():
    #     lambda_handler()

    # def test_approve_action():
    #     lambda_handler()

    # def test_update_action():
    #     lambda_handler()

    # def test_already_submitted_action():
    #     lambda_handler()

    # def test_invalid_recipient_action():
    #     lambda_handler()

    # def test_count_reached_action():
    #     lambda_handler()