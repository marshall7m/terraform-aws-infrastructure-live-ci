_common_setup() {
  src_path="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../src" >/dev/null 2>&1 && pwd )"
  PATH="$src_path:$PATH"
  find "$src_path" -type f -exec chmod u+x {} \;
}