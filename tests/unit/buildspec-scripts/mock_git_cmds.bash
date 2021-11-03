#!/bin/bash

git() {
    args=("$@")

    case "${args[0]}" in 
        fetch)
            echo "MOCK: FUNCNAME=$FUNCNAME"
        ;;
        *)
            # if none of the git args match, then run git as is
            "$(which git)" "$@"
        ;;
    esac
}

export -f git