import hashlib
import hmac
import re
import urllib
import boto3
import os


def aws_encode(value):
    """Encodes value into AWS friendly URL component"""
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))

class ClientException(Exception):
    """Wraps around client-related errors"""

    pass

class ServerException(Exception):
    """Wraps around server-related errors"""

    pass


def get_email_approval_sig(function_uri, method, recipient):
    ssm = boto3.client('ssm')

    secret = ssm.get_parameter(
        Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    data = function_uri + method + recipient
    sig = hmac.new(
        bytes(str(secret), "utf-8"), bytes(str(data), "utf-8"), hashlib.sha256
    ).hexdigest()

    return sig