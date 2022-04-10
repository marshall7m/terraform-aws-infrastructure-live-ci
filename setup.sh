#!/bin/bash

function usage()
{
  cat << HEREDOC
  Usage: setup.sh [--local] [--remote]

  Arguments:
  --help          Show this help message
  --local         In addition to the main container, a separate container containing a Postgres database will be created (useful for locally testing queries)
  --remote        Execs into the main container. Requires environment variables for AWS credentials to be set.
HEREDOC
}  

while [[ $# -gt 0 ]]; do
  case $1 in
    --local)
      type="local"
      shift
      ;;
    --remote)
      type="remote"
      shift
      ;;
    --help)
      usage; exit;
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

echo "Testing Environment: $type"

if [ "$type" == "local" ]; then
  # config for local metadb container
  export PGUSER=testing_user
  export PGPASSWORD=testing_password
  export PGDATABASE=testing_metadb
  export PGHOST=postgres
  export PGPORT=5432
  export ADDITIONAL_PATH=/src/node_modules/.bin

  docker-compose up --detach
  docker-compose exec testing /bin/bash
elif [ "$type" == "remote" ]; then
  
  docker-compose run \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_REGION \
    -e AWS_DEFAULT_REGION \
    -e AWS_SESSION_TOKEN \
    -e GITHUB_TOKEN \
    -v /var/run/docker.sock:/var/run/docker.sock `# allows running docker commands within container` \
    testing /bin/bash
else
  echo 'Testing environment is not set -- choose: `--local` | `--remote`' && exit 1
fi