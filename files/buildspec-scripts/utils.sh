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
  log "FUNCNAME=$FUNCNAME" "DEBUG"
	# export PGUSER=$TESTING_POSTGRES_USER
	# export PGDATABASE=$TESTING_POSTGRES_DB
	
	if [ "$METADB_TYPE" == "local" ]; then
    args=("$@")
    for i in "${!args[@]}"; do
      if [ "${args[i]}" == "-f" ]; then
          sql_file="${args[i+1]}"
          sql_cmd=$(cat "$sql_file")
          unset 'args[i]'
          unset 'args[i+1]'
      elif [ "${args[i]}" == "-c" ]; then
          sql_cmd="${args[i+1]}"
      fi
    done

    log "SQL command:" "DEBUG"
    log "$sql_cmd" "DEBUG"

    if [ -n "$sql_file" ]; then
      log "Piping sql file content to psql -c instead of having to mount or cp file to container" "DEBUG"
      cat "$sql_file" | docker exec --interactive "$CONTAINER_NAME" psql \
        -U "$TESTING_POSTGRES_USER" \
        -d "$TESTING_POSTGRES_DB" \
        -h /run/postgresql \
        "${args[*]}"
    else
      docker exec --interactive "$CONTAINER_NAME" psql \
      -U "$TESTING_POSTGRES_USER" \
      -d "$TESTING_POSTGRES_DB" \
      -h /run/postgresql \
      "$@"
    fi

  elif [ "$METADB_TYPE" == "aws" ]; then
    psql \
    --host="$RDS_ENDPOINT" \
    --port="$RDS_PORT" \
    --username="$RDS_USERNAME" \
    --password \
    --dbname="$RDS_DB" \
    "$@"
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

bash_arr_to_psql_arr() {
  local arr=$1
  printf -v psql_array "'%s'," "${arr[@]//\'/\'\'}"
  # remove the trailing ,
  psql_array=${psql_array%,}

  echo "($psql_array)"
}


jq_to_psql_records() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local jq_in=$1
	local table=$2

  if [ -z "$jq_in" ]; then
    log "jq_in is not set" "ERROR"
    exit 1
  elif [ -z "$table" ]; then
    log "table is not set" "ERROR"
    exit 1
  fi
  
  if table_exists "$table"; then
    log "Adding to existing table" "DEBUG"
  else
    log "Table does not exists -- creating table" "DEBUG"
    cols=$(echo "$jq_in" | jq '
    def psql_cols(in):
      {
        "number": "INT", 
        "string": "VARCHAR", 
        "array": "ARRAY[]",
        "boolean": "BOOL"
      } as $psql_types
      | if (in | type) == "array" then 
      map(. | to_entries | map(.key + " " + (.value | type | $psql_types[.])))
      else
      in | to_entries | map(.key + " " + (.value | type | $psql_types[.]))
      end
      | flatten | unique | join(", ")
      ;
    psql_cols(.)
    ' | tr -d '"')

    log "Columns: $cols" "DEBUG"

    query -c "CREATE TABLE IF NOT EXISTS $table ( $cols );"
  fi

  csv_table=$(echo "$jq_in" | jq -r '
    if . | type == "array" then .[] else . end
    | map(if values | type == "array" then values |= "{" + join(", ") + "}" else . end) | @csv')

  log "JQ transformed to CSV strings" "DEBUG"
	log "$csv_table" "DEBUG"

  log "Loading to table" "INFO"
	echo "$csv_table" | query -c "COPY $table FROM STDIN DELIMITER ',' CSV"
}