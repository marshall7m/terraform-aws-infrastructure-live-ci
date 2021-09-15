#!/bin/bash
_common_setup() {
  src_path="$( cd "$( dirname "$BASH_SOURCE[0]" )/../../../../../../files/buildspec-scripts" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  chmod u+x "$src_path"
  
  load "$src_path/utils.sh"

  export -f query
  export -f jq_to_psql_records
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
  log "FUNCNAME=$FUNCNAME" "DEBUG"
  if [ "$BATS_TEST_NUMBER" -ne "$1" ]; then
    skip
  fi
}

teardown_test_case_tmp_dir() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"\

  if [ $BATS_TEST_COMPLETED ]; then
    rm -rf $BATS_TEST_TMPDIR
    echo "Removed test case directory, as test case succeeded"
  else
    export BATS_TEST_FAILED=true
    echo "Did not delete $BATS_TEST_TMPDIR, as test failed"
  fi
}

teardown_test_file_tmp_dir() {
  log "FUNCNAME=$FUNCNAME" "DEBUG"

  if [ -n "$BATS_TEST_FAILED" ]; then 
    echo "Did not delete $BATS_FILE_TMPDIR, as atleast one test failed"
  else
    # rm -rf "$BATS_FILE_TMPDIR"
    echo "Removed test file directory, as test file succeeded"
  fi
}