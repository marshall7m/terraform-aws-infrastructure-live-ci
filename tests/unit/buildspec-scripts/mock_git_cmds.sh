#!/bin/bash

git() {
    for arg in "$@"; do
        case "$arg" in 
            fetch)
                echo "MOCK: FUNCNAME=$FUNCNAME"
                exit 0
            ;;
        esac
    done

    # if none of the git args match, then run git as is
    "$(which git)" "$@"
}

export -f git