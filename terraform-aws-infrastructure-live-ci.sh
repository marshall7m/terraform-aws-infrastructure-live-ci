#!/bin/bash

VERSION=0.0.1

usage () {
  echo "terraform-aws-infrastructure-live-ci [-hV]"
  echo
  echo "Options:"
  echo "  -h|--help      Print this help dialogue and exit"
  echo "  -V|--version   Print the current version and exit"
}

terraform-aws-infrastructure-live-ci () {
  for opt in "${@}"; do
    case "$opt" in
      -h|--help)
        usage
        return 0
        ;;
      -V|--version)
        echo "$VERSION"
        return 0
        ;;
    esac
  done

  ## your code here
}

if [[ ${BASH_SOURCE[0]} != $0 ]]; then
  export -f terraform-aws-infrastructure-live-ci
else
  terraform-aws-infrastructure-live-ci "${@}"
  exit $?
fi
