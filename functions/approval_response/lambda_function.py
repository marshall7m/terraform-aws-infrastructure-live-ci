import logging
import sys
from pprint import pformat
import os

sys.path.append(os.path.dirname(__file__))
from app import App, ApprovalHandler

sys.path.append(os.path.dirname(__file__) + "/..")
from common_lambda.utils import aws_response, ClientException

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


app = App()


@app.vote(method="post", path="/ses")
@app.validate_ses_request
def ses_approve(event):
    try:
        response = app.update_vote(
            execution_arn=event["queryStringParameters"]["exArn"],
            action=event["queryStringParameters"]["action"],
            voter=event["queryStringParameters"]["recipient"],
            task_token=event["queryStringParameters"]["taskToken"],
        )
    except ClientException as e:
        response = {"statusCode": 400, "body": e}
    except Exception as e:
        log.error(e, exc_info=True)
        response = {
            "statusCode": 500,
            "body": "Internal server error -- Unable to process vote",
        }
    finally:
        return aws_response(response)


def lambda_handler(event, context):
    """
    Handler will direct the request to the approriate function by the event's
    method and path
    """
    log.info(f"Event:\n{pformat(event)}")

    handler = ApprovalHandler(app=app)
    response = handler.handle(event, context)
    log.debug(f"Response:\n{response}")
    return response
