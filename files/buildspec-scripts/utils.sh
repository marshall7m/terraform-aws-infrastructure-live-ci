#!/bin/bash

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

    cols_types=$(echo "$jq_in" | jq '
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

    log "Columns Types: $cols_types" "DEBUG"

    query -c "CREATE TABLE IF NOT EXISTS $table ( $cols_types );"
  fi

  # get array of cols for psql insert/select for explicit column ordering
  col_order=$(echo "$jq_in" | jq 'if (. | type) == "array" then map(keys) else keys end | flatten | unique')
  log "Column order: $col_order" "DEBUG"

  csv_table=$(echo "$jq_in" | jq -r --arg col_order "$col_order" '
    ($col_order | fromjson) as $col_order
    | if (. | type) == "array" then .[] else . end
    | map_values(if (. | type) == "array" then . |= "{" + join(", ") + "}" else . end) as $stage
    | $col_order | map($stage[.]) | @csv
  ')

  log "JQ transformed to CSV strings" "DEBUG"
	log "$csv_table" "DEBUG"

  psql_cols=$(echo "$col_order" | jq 'join(", ")' | tr -d '"')
  log "Loading to table" "INFO"
	echo "$csv_table" | query -c "COPY $table ($psql_cols) FROM STDIN DELIMITER ',' CSV"
}