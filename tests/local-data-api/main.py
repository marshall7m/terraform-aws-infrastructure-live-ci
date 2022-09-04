from typing import Any, Dict, List, Optional
import os

from fastapi import FastAPI
from starlette.requests import Request
from starlette.responses import JSONResponse

from local_data_api.exceptions import DataAPIException
from local_data_api.models import (
    BatchExecuteStatementRequests,
    BatchExecuteStatementResponse,
    BeginTransactionRequest,
    BeginTransactionResponse,
    CommitTransactionRequest,
    CommitTransactionResponse,
    ExecuteSqlRequest,
    ExecuteStatementRequests,
    ExecuteStatementResponse,
    RollbackTransactionRequest,
    RollbackTransactionResponse,
    TransactionStatus,
    UpdateResult,
)
from local_data_api.resources.resource import Resource, get_resource, RESOURCE_METAS
from local_data_api.secret_manager import SECRETS
from local_data_api.settings import setup

app = FastAPI()

setup()


def mock_request(request):
    """
    Returns request object with overridden request attributes to allow all testing rds-data requests
    to be sent to local metadb container.

    For sake of testing, the attributes below are overridden with the initial attributes used to spin up the container
    in order for testing requests to bypass cluster, secret and database lookup.
    Reason being that original docker img only registers valid secret ARNs within local-data-api container start.sh
    which prevents registering testing Terraform module secret ARNs after the
    the Terraform module creates the secret. The local-data-api container can't be spinned up after
    the Terraform module is provisioned given that the sql/metadb_setup_script.sh has a
    dependency on the local-data-api container
    """
    request.secretArn = list(SECRETS.keys())[0]
    request.resourceArn = list(RESOURCE_METAS.keys())[0]
    # POSTGRES_DB env var provided by docker compose (value must be same as local postgres db)
    if hasattr(request, "database"):
        request.database = os.environ["POSTGRES_DB"]
    return request


@app.post("/ExecuteSql")
def execute_sql(request: ExecuteSqlRequest) -> None:
    raise NotImplementedError


@app.post("/BeginTransaction", response_model=BeginTransactionResponse)
def begin_statement(request: BeginTransactionRequest) -> BeginTransactionResponse:
    request = mock_request(request)
    resource: Resource = get_resource(
        request.resourceArn, request.secretArn, database=request.database
    )
    transaction_id: str = resource.begin()

    return BeginTransactionResponse(transactionId=transaction_id)


@app.post("/CommitTransaction", response_model=CommitTransactionResponse)
def commit_transaction(request: CommitTransactionRequest) -> CommitTransactionResponse:
    request = mock_request(request)
    resource: Resource = get_resource(
        request.resourceArn, request.secretArn, request.transactionId
    )
    resource.commit()
    resource.close()
    return CommitTransactionResponse(
        transactionStatus=TransactionStatus.transaction_committed
    )


@app.post("/RollbackTransaction", response_model=RollbackTransactionResponse)
def rollback_transaction(
    request: RollbackTransactionRequest,
) -> RollbackTransactionResponse:
    request = mock_request(request)
    resource: Resource = get_resource(
        request.resourceArn, request.secretArn, request.transactionId
    )
    resource.rollback()
    resource.close()

    return RollbackTransactionResponse(
        transactionStatus=TransactionStatus.rollback_complete
    )


@app.post(
    "/Execute",
    response_model=ExecuteStatementResponse,
    response_model_exclude_unset=True,
)
def execute_statement(request: ExecuteStatementRequests) -> ExecuteStatementResponse:
    resource: Optional[Resource] = None
    try:
        request = mock_request(request)
        resource = get_resource(
            request.resourceArn,
            request.secretArn,
            request.transactionId,
            request.database,
        )

        if not resource.transaction_id:
            resource.autocommit_off()

        if request.parameters:
            parameters: Optional[Dict[str, Any]] = {
                parameter.name: parameter.valid_value
                for parameter in request.parameters
            }
        else:
            parameters = None

        response: ExecuteStatementResponse = resource.execute(
            request.sql,
            parameters,
            include_result_metadata=request.includeResultMetadata,
        )

        if not resource.transaction_id:
            resource.commit()
        return response
    finally:
        if resource and not resource.transaction_id:
            resource.close()


@app.post(
    "/BatchExecute",
    response_model=BatchExecuteStatementResponse,
    response_model_exclude_unset=True,
)
def batch_execute_statement(
    request: BatchExecuteStatementRequests,
) -> BatchExecuteStatementResponse:
    resource: Optional[Resource] = None
    try:
        request = mock_request(request)
        resource = get_resource(
            request.resourceArn,
            request.secretArn,
            request.transactionId,
            request.database,
        )

        update_results: List[UpdateResult] = []

        if not resource.transaction_id:
            resource.autocommit_off()

        if not request.parameterSets:
            response: BatchExecuteStatementResponse = BatchExecuteStatementResponse(
                updateResults=update_results
            )
        else:
            for parameter_set in request.parameterSets:
                parameters: Dict[str, Any] = {
                    parameter.name: parameter.valid_value for parameter in parameter_set
                }
                result: ExecuteStatementResponse = resource.execute(
                    request.sql, parameters
                )

                if result.generatedFields:
                    update_results.append(
                        UpdateResult(generatedFields=result.generatedFields)
                    )

            response = BatchExecuteStatementResponse(updateResults=update_results)

        if not resource.transaction_id:
            resource.commit()
        return response
    finally:
        if resource and not resource.transaction_id:
            resource.close()


@app.exception_handler(DataAPIException)
async def data_api_exception_handler(_: Request, exc: DataAPIException) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code, content={"message": exc.message, "code": exc.code}
    )


if __name__ == "__main__":
    from uvicorn import run

    run(app=app, port=8080)
