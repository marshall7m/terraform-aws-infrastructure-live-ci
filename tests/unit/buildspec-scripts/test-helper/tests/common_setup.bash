_common_setup() {
  src_path="$( cd "$( dirname "$BASH_SOURCE" )/../src" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  chmod u+x "$src_path/"

  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" >/dev/null 2>&1 && pwd )/../load.bash"

  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.sh"
  load "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bats-utils/load.sh"
}
