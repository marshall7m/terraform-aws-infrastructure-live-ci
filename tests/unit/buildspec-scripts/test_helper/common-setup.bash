#!/bin/bash

_common_setup() {
  dir="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
  src_path="$dir/../../../files/buildspec-scripts"
  PATH="$src_path:$PATH"
  chmod u+x "$src_path"
  
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  load 'test_helper/utils'
}