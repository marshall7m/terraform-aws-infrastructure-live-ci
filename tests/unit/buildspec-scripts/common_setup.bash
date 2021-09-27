#!/bin/bash
_common_setup() {
  # add testing directory to PATH
  src_path="$( cd "$( dirname "$BASH_SOURCE[0]" )/../.././../files/buildspec-scripts" >/dev/null 2>&1 && pwd )"
  export PATH="$src_path:$PATH"
  chmod u+x "$src_path"
}