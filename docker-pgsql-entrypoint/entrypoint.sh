#!/bin/bash

psql -v ON_ERROR_STOP=1 \
--variable=POSTGRES_USER="$POSTGRES_USER" \
--variable=TESTING_POSTGRES_USER="$TESTING_POSTGRES_USER" \
--variable=TESTING_POSTGRES_USER_PASSWORD="$POSTGRES_PASSWORD" \
--variable=TESTING_POSTGRES_DB="$TESTING_POSTGRES_DB" <<-EOSQL
CREATE USER :TESTING_POSTGRES_USER
PASSWORD :TESTING_POSTGRES_USER_PASSWORD;
GRANT :POSTGRES_USER to :TESTING_POSTGRES_USER;
CREATE DATABASE :TESTING_POSTGRES_DB;
GRANT ALL PRIVILEGES ON DATABASE :TESTING_POSTGRES_DB TO :TESTING_POSTGRES_USER;

\c :TESTING_POSTGRES_DB

set plpgsql.check_asserts to on;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO :TESTING_POSTGRES_USER;

SET ROLE :TESTING_POSTGRES_USER;
EOSQL

count=0
timeout_sec=300
sleep_sec=30

echo "Timeout (sec): $timeout_sec"
echo "Sleep (sec): $sleep_sec"

psql -c "SELECT 1"
while [ $? -ne 0 ]; do
	if (( $count > $timeout_sec )); then
		echo >&2 "Timeout has been reached -- exiting"
		exit 1
	fi
	
	echo "db is not ready yet -- sleeping $sleep_sec seconds"
	sleep "$sleep_sec"
	count=$(( count + "$sleep_sec" ))
	echo "Total wait time: $count"
	psql -c "SELECT 1"
done