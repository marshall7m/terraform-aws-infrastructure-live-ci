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

get_pr_queue() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"

  aws s3api get-object \
  --bucket $ARTIFACT_BUCKET_NAME \
  --key $ARTIFACT_BUCKET_PR_QUEUE_KEY \
  pr_queue.json > /dev/null || exit 1

  echo $(jq . pr_queue.json)
}

upload_pr_queue() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"
  
  local pr_queue=$1

  echo "$pr_queue" > $pr_queue.json
  aws s3api put-object \
      --acl private \
      --body ./pr_queue.json \
      --bucket $ARTIFACT_BUCKET_NAME \
      --key $ARTIFACT_BUCKET_PR_QUEUE_KEY.json
}