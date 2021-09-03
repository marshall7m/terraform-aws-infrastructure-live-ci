#!/bin/bash

_common_setup() {
  src_path="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../../../files/buildspec-scripts" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  chmod u+x "$src_path"
  
  load "$src_path/utils.sh"

  #use src query() function within testing
  export -f query
}

log() {
  declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
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

run_only_test() {
  if [ "$BATS_TEST_NUMBER" -ne "$1" ]; then
    skip
  fi
}