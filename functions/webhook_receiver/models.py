import os
import sys
import json
from typing import Any
import hmac
import hashlib
import re

import github
import boto3
from pydantic import (
    BaseModel,
    validator,
    Field,
    Extra,
    root_validator,
    Json,
)

sys.path.append(os.path.dirname(__file__))
from exceptions import InvalidSignatureError, FilePathsNotMatched
from utils import aws_encode

ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))


class Headers(BaseModel):
    x_github_event: str = Field(alias="x-github-event")
    x_hub_signature_256: str = Field(alias="x-hub-signature-256")

    @validator("x_github_event")
    def validate_github_event(cls, val):
        if val != "pull_request":
            raise ValueError("Event is not a pull request")
        return val

    @validator("x_hub_signature_256")
    def validate_sig_prefix(cls, val):

        if not val.startswith("sha256="):
            raise InvalidSignatureError("Signature is not a valid sha256 value")
        return val

    class Config:
        extra = Extra.ignore


class Repository(BaseModel):
    full_name: str

    class Config:
        extra = Extra.ignore


class Base(BaseModel):
    sha: str
    ref: str

    class Config:
        extra = Extra.ignore


class Head(BaseModel):
    sha: str
    ref: str

    class Config:
        extra = Extra.ignore


class PullRequest(BaseModel):
    merged: bool
    base: Base
    head: Head
    number: int

    class Config:
        extra = Extra.ignore


class Body(BaseModel):
    repository: Repository
    pull_request: PullRequest
    action: str

    commit_status_config: dict[str, bool] = None

    class Config:
        extra = Extra.ignore

    @root_validator(skip_on_failure=True)
    def validate_file_path(cls, values):
        # sets token env var so downstream github clients can use it
        os.environ["GITHUB_TOKEN"] = ssm.get_parameter(
            Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
        )["Parameter"]["Value"]

        gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])
        repo = gh.get_repo(values["repository"].full_name)

        diff_filepaths = [
            path.filename
            for path in repo.compare(
                values["pull_request"].base.sha,
                values["pull_request"].head.sha,
            ).files
        ]

        for path in diff_filepaths:
            if re.search(os.environ["FILE_PATH_PATTERN"], path):
                return values

        raise FilePathsNotMatched(
            f"No diff filepath was matched within pattern: {os.environ['FILE_PATH_PATTERN']}"
        )

    @validator("commit_status_config", pre=True, always=True)
    def set_commit_status_config(cls, val):
        return json.loads(
            ssm.get_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"])[
                "Parameter"
            ]["Value"]
        )


class Event(BaseModel):
    headers: Headers
    body: Json[Any]

    @root_validator(pre=True)
    def validate_sig_content(cls, values):
        actual_sig = str(values.get("headers").get("x-hub-signature-256"))
        if not actual_sig.startswith("sha256="):
            raise InvalidSignatureError("Signature is not a valid sha256 value")

        secret = ssm.get_parameter(
            Name=os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"], WithDecryption=True
        )["Parameter"]["Value"]
        expected_sig = hmac.new(
            bytes(str(secret), "utf-8"),
            bytes(str(values.get("body")), "utf-8"),
            hashlib.sha256,
        ).hexdigest()

        authorized = hmac.compare_digest(actual_sig.split("=", 1)[1], str(expected_sig))

        if not authorized:
            raise InvalidSignatureError(
                "Header signature and expected signature do not match"
            )

        return values

    @validator("body")
    def parse(cls, val):
        return Body(**val)

    class Config:
        extra = Extra.ignore


class Context(BaseModel):
    log_group_name: str
    log_stream_name: str
    logs_url: str = None

    @validator("logs_url", always=True)
    def set_logs_url(cls, val, values):
        return f'https://{os.environ.get("AWS_REGION")}.console.aws.amazon.com/cloudwatch/home?region={os.environ.get("AWS_REGION")}#logsV2:log-groups/log-group/{aws_encode(values["log_group_name"])}/log-events/{aws_encode(values["log_stream_name"])}'

    class Config:
        extra = Extra.ignore
