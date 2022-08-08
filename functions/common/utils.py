import hashlib
import hmac
import re
import urllib.parse
import urllib
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


def aws_decode(value):
    """Decodes AWS friendly URL component"""
    value = urllib.parse.unquote_plus(re.sub(r"\$", "%", value))
    value = re.sub(r"\s", "+", value)
    return urllib.parse.unquote_plus(value)


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


def get_email_approval_sig(
    secret, execution_id: str, recipient: str, action: str
) -> str:
    """
    Returns signature used to authenticate AWS SES approval requests

    Arguments:
        execution_id: Step Function execution ID
        recipient: Email address associated with the approval request
        action: Approval action (e.g. approve, reject)
    """
    data = execution_id + recipient + action
    sig = hmac.new(
        bytes(str(secret), "utf-8"), bytes(str(data), "utf-8"), hashlib.sha256
    ).hexdigest()

    return sig


def validate_sig(actual_sig: str, expected_sig: str):
    """
    Authenticates request by comparing the request's SHA256
    signature value to the expected SHA-256 value
    """

    log.debug(f"Actual: {actual_sig}")
    log.debug(f"Expected: {expected_sig}")

    authorized = hmac.compare_digest(str(actual_sig), str(expected_sig))

    if not authorized:
        raise ClientException("Header signature and expected signature do not match")
