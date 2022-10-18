import sys
import os

from starlette.requests import Request
from starlette.responses import Response, JSONResponse
from fastapi import FastAPI
from mangum import Mangum

sys.path.append(os.path.dirname(__file__))
from models import LambdaFunctionUrlRequest
from invoker import merge_lock, trigger_pr_plan, trigger_create_deploy_stack
from exceptions import InvalidSignatureError, FilePathsNotMatched

app = FastAPI()


@app.post("/open")
def open_pr(request: LambdaFunctionUrlRequest):
    merge_lock(
        request.body.respository.full_name,
        request.body.pull_request.head.ref,
        request._log_url,
    )

    trigger_pr_plan(
        request.body.respository.full_name,
        request.body.pull_request.base.ref,
        request.body.pull_request.head.ref,
        request.body.pull_request.head.sha,
        request._log_url,
        request._commit_status_config.get("PrPlan"),
    )

    return Response("foo")


@app.post("/merge")
def merged_pr(request: LambdaFunctionUrlRequest):

    trigger_create_deploy_stack(
        request.body.respository.full_name,
        request.body.pull_request.base.ref,
        request.body.pull_request.head.ref,
        request.body.pull_request.head.sha,
        request.body.pull_request.number,
        request._log_url,
        request._commit_status_config.get("CreateDeployStack"),
    )


@app.exception_handler(ValueError)
async def value_error_exception_handler(request: Request, exc: ValueError):
    return JSONResponse(
        status_code=400,
        content={"message": str(exc)},
    )


@app.middleware("http")
async def add_resource_path(request: Request, call_next):
    try:
        LambdaFunctionUrlRequest(event=request.scope["aws.event"])
    except InvalidSignatureError as e:
        return JSONResponse(status_code=403, content=str(e))
    except FilePathsNotMatched as e:
        return JSONResponse(status_code=200, content=str(e))
    response = await call_next(**request)
    return response


handler = Mangum(app, lifespan="off")
