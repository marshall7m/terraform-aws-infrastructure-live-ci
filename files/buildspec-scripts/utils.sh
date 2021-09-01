#!/bin/bash

log() {
  declare levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
  local log_message=$1
  local log_priority=$2

  #check if level exists
  [[ ${levels[$log_priority]} ]] || return 1

  #check if level is enough
  # returns exit status 0 instead of 2 to prevent `set -e ` from exiting if log priority doesn't meet log level
  (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return

  # redirects log message to stderr (>&2) to prevent cases where sub-function
  # uses log() and sub-function stdout results and log() stdout results are combined
  echo "${log_priority} : ${log_message}" >&2
}

check_for_env_var() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"

  local env_var=
  env_var=$(declare -p "$1")
  if ! [ -v "$1" && $env_var =~ ^declare\ -x ]; then
    log "Environment Variable: $1 is not defined" "ERROR"
    exit 1
  fi
}

var_exists() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"
  if [ -n "$1" ]; then
    return 0
  else
    return 1
  fi
}

query() {
	set -e
	log "FUNCNAME=$FUNCNAME" "DEBUG"

  local sql=$1
  log "Query:" "DEBUG"
  log "$sql" "DEBUG"
	
	# export PGUSER=$TESTING_POSTGRES_USER
	# export PGDATABASE=$TESTING_POSTGRES_DB
	
	if [ "$METADB_TYPE" == "local" ]; then
		docker exec "$CONTAINER_NAME" psql -U "$TESTING_POSTGRES_USER" -d "$TESTING_POSTGRES_DB" -c "$sql"

  elif [ "$METADB_TYPE" == "aws" ]; then
    aws rds-data execute-statement \
      --database "$RDS_DB"
      --resource-arn "$RDS_ARN"
      --secret-arn "$RDS_SECRET_ARN"
      --sql "$sql"

	else
		log "METADB_TYPE is not set (local|aws)" "ERROR"
	fi
}

get_artifact() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"
  
  local bucket=$1
  local key=$2

  tmp_file="$(mktemp -d)/artifact.json"
  log "Uploading Artifact to tmp directory: $tmp_file" "DEBUG"

  aws s3api get-object  \
      --bucket $bucket \
      --key $key.json \
      $tmp_file > /dev/null || exit 1

  log "Getting Artifact" "DEBUG"
  echo $(jq . $tmp_file)
}

upload_artifact() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"
  
  local bucket=$1
  local key=$2
  local artifact=$3

  tmp_file="$(mktemp -d)/artifact.json"
  log "Writing Artifact to tmp directory: $tmp_file" "DEBUG"
  echo "$artifact" > $tmp_file
  
  log "Uploading Artifact" "DEBUG"
  aws s3api put-object \
      --acl private \
      --body $tmp_file \
      --bucket $bucket \
      --key $key.json
}