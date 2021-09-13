_common_setup() {
  src_path="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../src" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  chmod u+x "$src_path"

  #load common setup from src
  load '../load.bash'
  _common_setup 

}
