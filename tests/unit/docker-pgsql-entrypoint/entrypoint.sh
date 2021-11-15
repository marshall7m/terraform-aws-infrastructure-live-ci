#!/bin/bash

psql -U postgres <<EOF
CREATE USER $TESTING_POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';
GRANT $POSTGRES_USER to $TESTING_POSTGRES_USER;
EOF

psql -U postgres <<EOF
CREATE DATABASE $TESTING_POSTGRES_DB;
GRANT ALL PRIVILEGES ON DATABASE $TESTING_POSTGRES_DB TO $TESTING_POSTGRES_USER;
EOF

psql -U postgres <<EOF
-- may have to switch to TESTING_POSTGRES_DB before setting check_asserts
set plpgsql.check_asserts to on;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $TESTING_POSTGRES_USER;

SET ROLE $TESTING_POSTGRES_USER;
EOF

count=0
timeout_sec=300
sleep_sec=30

echo "Timeout (sec): $timeout_sec"
echo "Sleep (sec): $sleep_sec"

psql -U postgres -c "SELECT 1"
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