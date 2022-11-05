import os
import sys
from typing import Any
import hmac

import boto3
from pydantic import (
    BaseModel,
    validator,
    Field,
    Extra,
    Json,
)

sys.path.append(os.path.dirname(__file__))
from exceptions import InvalidSignatureError
from utils import voter_actions, aws_decode, get_email_approval_sig

ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))


class RequestContext(BaseModel):
    http: str


class QueryStringParameters(BaseModel):
    ex: str
    recipient: str
    action: str
    exArn: str
    taskToken: str
    x_ses_signature_256: str = Field(alias="X-SES-Signature-256")

    @validator("X-SES-Signature-256")
    def validate_sig_content(cls, v, values, **kwargs):
        if not v.startswith("sha256="):
            raise InvalidSignatureError("Signature is not a valid sha256 value")

        secret = ssm.get_parameter(
            Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
        )["Parameter"]["Value"]

        expected_sig = get_email_approval_sig(
            secret,
            values["ex"],
            aws_decode(values["recipient"]),
            values["action"],
        )

        authorized = hmac.compare_digest(v.rsplit("=", maxsplit=1)[-1], expected_sig)

        if not authorized:
            raise InvalidSignatureError(
                "Header signature and expected signature do not match"
            )

        return values

    @validator("action")
    def validate_action(cls, v):
        if v not in voter_actions:
            raise ValueError(f"Voting action is not valid: {v}")


class SESEvent(BaseModel):
    body: Json[Any]
    queryStringParameters: QueryStringParameters
    requestContext: RequestContext

    class Config:
        extra = Extra.ignore
