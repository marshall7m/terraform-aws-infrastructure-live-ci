import logging
import sys
import os

from starlette.requests import Request
from starlette.responses import JSONResponse
from fastapi import FastAPI
from mangum import Mangum

sys.path.append(os.path.dirname(__file__))
from app import update_vote
from exceptions import InvalidSignatureError, ExpiredVote
from models import SESEvent

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

app = FastAPI()


@app.exception_handler(ValueError)
async def value_error_exception_handler(request: Request, exc: ValueError):
    return JSONResponse(
        status_code=400,
        content={"message": str(exc)},
    )


@app.exception_handler(InvalidSignatureError)
async def invalid_signature_error_exception_handler(request: Request, exc: ValueError):
    return JSONResponse(
        status_code=403,
        content={"message": str(exc)},
    )


@app.exception_handler(ExpiredVote)
async def expired_vote_error_exception_handler(request: Request, exc: ValueError):
    return JSONResponse(
        status_code=410,
        content={"message": str(exc)},
    )


@app.post("/ses")
def ses_approve(request: Request):
    event = SESEvent(**request.scope["aws.event"])
    update_vote(
        execution_arn=event.queryStringParameters.exArn,
        execution_id=event.queryStringParameters.ex,
        action=event.queryStringParameters.action,
        voter=event.queryStringParameters.recipient,
        task_token=event.queryStringParameters.taskToken,
    )

    return JSONResponse(
        status_code=200,
        content={"message": "Vote was successfully submitted"},
    )


handler = Mangum(app, lifespan="off")
