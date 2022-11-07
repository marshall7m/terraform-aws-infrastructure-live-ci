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


voter_actions = ["approve", "reject"]


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
