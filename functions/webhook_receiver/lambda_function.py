import sys
import os
import logging

from starlette.requests import Request
from starlette.responses import JSONResponse
from fastapi import FastAPI
from mangum import Mangum

sys.path.append(os.path.dirname(__file__))
from models import Event, Context
from invoker import merge_lock, trigger_pr_plan, trigger_create_deploy_stack
from exceptions import InvalidSignatureError, FilePathsNotMatched
from utils import get_logger

log = get_logger()
log.setLevel(logging.DEBUG)

app = FastAPI()


@app.post("/open")
def open_pr(request: Request):
    event = Event(**request.scope["aws.event"])
    context = Context(**request.scope["aws.context"].__dict__)

    merge_lock(
        event.body.repository.full_name,
        event.body.pull_request.head.ref,
        context.logs_url,
    )

    trigger_pr_plan(
        event.body.repository.full_name,
        event.body.pull_request.base.ref,
        event.body.pull_request.head.ref,
        event.body.pull_request.head.sha,
        context.logs_url,
        event.body.commit_status_config.get("PrPlan"),
    )

    return JSONResponse(
        status_code=200,
        content={"message": "Request was successful"},
    )


@app.post("/merge")
def merged_pr(request: Request):
    event = Event(**request.scope["aws.event"])
    context = Context(**request.scope["aws.context"].__dict__)

    trigger_create_deploy_stack(
        repo_full_name=event.body.repository.full_name,
        base_ref=event.body.pull_request.base.ref,
        head_ref=event.body.pull_request.head.ref,
        base_sha=event.body.pull_request.base.sha,
        head_sha=event.body.pull_request.head.sha,
        pr_id=event.body.pull_request.number,
        logs_url=context.logs_url,
        send_commit_status=event.body.commit_status_config.get("CreateDeployStack"),
    )

    return JSONResponse(
        status_code=200,
        content={"message": "Request was successful"},
    )


@app.exception_handler(ValueError)
async def value_error_exception_handler(request: Request, exc: ValueError):
    return JSONResponse(
        status_code=400,
        content={"message": str(exc)},
    )


@app.exception_handler(InvalidSignatureError)
async def invalid_signature_error_exception_handler(
    request: Request, exc: InvalidSignatureError
):
    return JSONResponse(
        status_code=403,
        content={"message": str(exc)},
    )


@app.exception_handler(FilePathsNotMatched)
async def filepath_not_matched_error_exception_handler(
    request: Request, exc: FilePathsNotMatched
):
    return JSONResponse(
        status_code=200,
        content={"message": str(exc)},
    )


# TODO: add allowed_hosts=["github.com"] ?
@app.middleware("http")
async def add_resource_path(request: Request, call_next):
    body = await request.json()

    merged = body.get("pull_request", {}).get("merged")
    if body.get("action") in ["opened", "edited", "reopened"] and merged is False:
        request.scope["path"] = "/open"

    elif body.get("action") == "closed" and merged is True:
        request.scope["path"] = "/merge"

    log.debug("Resource Path: %s", request.scope["path"])

    response = await call_next(request)
    return response


handler = Mangum(app, lifespan="off")
