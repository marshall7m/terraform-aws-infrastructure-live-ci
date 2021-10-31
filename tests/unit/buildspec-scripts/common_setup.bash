#!/bin/bash
_common_setup() {
  src_path="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../../../files/buildspec-scripts" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  find "$src_path" -type f -exec chmod u+x {} \;

  log "Creating global postgres utility functions" "INFO"
  psql -f "$src_path/sql/utils.sql"
}