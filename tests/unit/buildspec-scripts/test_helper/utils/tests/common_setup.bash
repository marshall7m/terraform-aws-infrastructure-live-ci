_common_setup() {
  load "../src/common_setup.bash"
  _common_setup
  export -f log

  src_path="$( cd "$( dirname "$BASH_SOURCE" )/../src" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  chmod u+x "$src_path/"  
}
