import os
import sys
from typing import Any, Literal
import hmac

import boto3
from pydantic import BaseModel, Field, Extra, Json, root_validator

sys.path.append(os.path.dirname(__file__))
from exceptions import InvalidSignatureError
from utils import aws_decode, get_email_approval_sig

ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))


class RequestContext(BaseModel):
    http: dict


class QueryStringParameters(BaseModel):
    ex: str
    recipient: str
    action: Literal["approve", "reject"]
    exArn: str
    taskToken: str
    x_ses_signature_256: str = Field(alias="X-SES-Signature-256")

    @root_validator(skip_on_failure=True)
    def validate_sig_content(cls, values):
        values = {k: aws_decode(v) for k, v in values.items()}
        if not values["x_ses_signature_256"].startswith("sha256="):
            raise InvalidSignatureError("Signature is not a valid sha256 value")

        secret = ssm.get_parameter(
            Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
        )["Parameter"]["Value"]

        expected_sig = get_email_approval_sig(
            secret, values["ex"], aws_decode(values["recipient"]), values["action"]
        )

        authorized = hmac.compare_digest(
            values["x_ses_signature_256"].rsplit("=", maxsplit=1)[-1], expected_sig
        )

        if not authorized:
            raise InvalidSignatureError(
                "Header signature and expected signature do not match"
            )

        return values


class SESEvent(BaseModel):
    body: Json[Any]
    queryStringParameters: QueryStringParameters
    requestContext: RequestContext

    class Config:
        extra = Extra.ignore
