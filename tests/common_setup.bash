#!/bin/bash
_common_setup() {
  helper_path="$( cd "$BATS_TEST_DIRNAME/../test-helper" && pwd )"
  echo "helper: $helper_path"
  PATH="$helper_path:$PATH"
  find "$helper_path" -type f -exec chmod u+x {} \;

  log "Creating global postgres utility functions" "INFO"
  psql -f "$BATS_TEST_DIRNAME/../../files/buildspec-scripts/sql/utils.sql"
}