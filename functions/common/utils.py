import hashlib
import hmac
import re
import urllib
import boto3
import os
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class ClientException(Exception):
    """Wraps around client-related errors"""

    pass


class ServerException(Exception):
    """Wraps around server-related errors"""

    pass


def aws_encode(value):
    """Encodes value into AWS friendly URL component"""
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


def aws_response(
    response, status_code=200, content_type="application/json", isBase64Encoded=False
):
    if isinstance(response, str):
        return {
            "statusCode": status_code,
            "body": response,
            "headers": {"content-type": content_type},
            "isBase64Encoded": isBase64Encoded,
        }

    elif isinstance(response, dict):
        return {
            "statusCode": response.get("statusCode", status_code),
            "body": str(response.get("body", "")),
            "headers": {"content-type": response.get("content-type", content_type)},
            "isBase64Encoded": response.get("isBase64Encoded", isBase64Encoded),
        }

    elif isinstance(response, Exception):
        return {
            "statusCode": 500,
            "body": str(response),
            "headers": {"content-type": content_type},
            "isBase64Encoded": isBase64Encoded,
        }


def get_email_approval_sig(function_uri: str, method: str, recipient: str) -> str:

    ssm = boto3.client("ssm")

    secret = ssm.get_parameter(
        Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    data = function_uri + method + recipient
    sig = hmac.new(
        bytes(str(secret), "utf-8"), bytes(str(data), "utf-8"), hashlib.sha256
    ).hexdigest()

    return sig


def validate_sig(actual_sig: str, expected_sig: str):
    """
    Authenticates request by comparing the request's SHA256
    signature value to the expected SHA-256 value
    """

    log.info("Authenticating approval request")
    log.debug(f"Actual: {actual_sig}")
    log.debug(f"Expected: {expected_sig}")

    authorized = hmac.compare_digest(str(actual_sig), str(expected_sig))

    if not authorized:
        raise ClientException("Header signature and expected signature do not match")
