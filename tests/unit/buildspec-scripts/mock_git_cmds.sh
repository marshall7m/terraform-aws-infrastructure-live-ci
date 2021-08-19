#!/bin/bash

checkout_pr() {
    return
}

get_rel_path() {
    local rel_to=$1
    local path=$2
    
    # get relaive path even if it doesn't exists
    echo "$(xargs realpath -m --relative-to=$rel_to $path)"
}

get_git_source_versions() {
    base_source_version="MOCK: FUNCNAME=$FUNCNAME"
    head_source_version="MOCK: FUNCNAME=$FUNCNAME"
}