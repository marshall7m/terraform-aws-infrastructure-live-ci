#!/bin/bash
_common_setup() {
  # add testing directory to PATH
  src_path="$( cd "$( dirname "$BASH_SOURCE[0]" )/../.././../files/buildspec-scripts" >/dev/null 2>&1 && pwd )"
  export PATH="$src_path:$PATH"
  chmod u+x "$src_path"

  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.sh"
  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-support/load.sh"
  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-assert/load.sh"

  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" >/dev/null 2>&1 && pwd )/test-helper/load.sh"
}