#!/bin/bash

export POSTGRES_USER:="postgres"
export POSTGRES_PASSWORD:="testing_password"
export PGUSER:="testing_user"
export PGDATABASE:="testing_db"
export PGHOST:="/run/postgresql"

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