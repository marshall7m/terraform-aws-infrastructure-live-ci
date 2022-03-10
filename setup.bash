#!/bin/bash

echo "TESTING_ENV: $TESTING_ENV"
if [ "$TESTING_ENV" == "local" ]; then
    # config for local metadb container
    export PGUSER=testing_user
    export PGPASSWORD=testing_password
    export PGDATABASE=testing_metadb
    export PGHOST=postgres
    export PGPORT=5432
    export ADDITIONAL_PATH=/src/node_modules/.bin

    docker-compose up --detach
    docker-compose exec testing /bin/bash
elif [ "$TESTING_ENV" == "remote" ]; then
    # skips creating local metadb container
    docker-compose run \
        -e AWS_ACCESS_KEY_ID \
        -e AWS_SECRET_ACCESS_KEY \
        -e AWS_REGION \
        -e AWS_DEFAULT_REGION \
        -e AWS_SESSION_TOKEN \
        -e GITHUB_TOKEN \
        -v /var/run/docker.sock:/var/run/docker.sock \
        testing /bin/bash
else
    echo '$TESTING_ENV is not set -- (local | remote)' && exit 1
fi