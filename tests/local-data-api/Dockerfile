FROM koxudaxi/local-data-api:0.5.8
COPY ./main.py /app/local_data_api/main.py
# replace typeName=None with typeName="varchar" for all columns so that aurora-data-api doesn't raise KeyError on typeName
# NOTE: don't rely on typeName from rds-data execute results
COPY ./postgres.py /app/local_data_api/resources/postgres.py