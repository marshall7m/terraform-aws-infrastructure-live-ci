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

check_build_env_vars() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"

  set -e
  check_for_env_var "$ACCOUNT"
  check_for_env_var "$TARGET_PATH"
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