FROM public.ecr.aws/lambda/python:3.9

COPY requirements.txt  .
RUN  pip3 install -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

COPY lambda_function.py ${LAMBDA_TASK_ROOT}
COPY models.py ${LAMBDA_TASK_ROOT}
COPY invoker.py ${LAMBDA_TASK_ROOT}
COPY exceptions.py ${LAMBDA_TASK_ROOT}
COPY utils.py ${LAMBDA_TASK_ROOT}

CMD [ "lambda_function.handler" ]