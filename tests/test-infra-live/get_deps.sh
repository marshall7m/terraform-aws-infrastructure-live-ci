#!/bin/bash

declare -a levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="DEBUG"
logger() {
    local log_message=$1
    local log_priority=$2

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    #log here
    echo "${log_priority} : ${log_message}"
}

# pattern='^"\K.+(?="\s;$)'
pattern='^".+"(?=\s;$)'


if [ -n "$1" ]; then
    filepath="${1// /__REPLACED__SPACE__}"
    # gets abs path of modified directory
    modified_dir=$(cd $(dirname "$1") && pwd && cd - > /dev/null)
else
    echo "No filepath argument was passed"
    exit 1
fi

logger "modified directory path: ${modified_dir}" "DEBUG"
cd "$modified_dir" > /dev/null

deps=()
while read -r line; do
    if echo "$line" | grep -qP "$pattern" && [ "$PWD" != $( echo "$line" | grep -oP '"\K.+(?=")' ) ]; then
        match=$(echo "$line" | grep -oP "$pattern")
        deps+=("$match")
    fi
done < <(terragrunt graph-dependencies --terragrunt-non-interactive)

target_deps=()
# reverse list to change order to go from most implicit dependency to explicit dependency
echo
echo "deps before reverse:"
echo "${deps[@]}"
echo "deps after reverse:"
rev=$( reverse_arr "$deps" )
echo "${rev[@]}"
echo
for dep_dir in "${deps[@]}"; do
    logger "dependency directory path: ${dep_dir}" "DEBUG" 
    terragrunt plan --terragrunt-working-dir ${dep_dir} -detailed-exitcode >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        logger "Changes detected" "INFO"
        target_deps+=("$dep_dir")
    elif [ $? -eq 0 ]; then
        logger "No changes detected" "INFO"
    else
        logger "Error running terragrunt plan within directory: ${dep_dir}" "ERROR"
    fi
done

# add modified directory argument to end of arr
target_deps+=("$modified_dir")
echo "${target_deps[@]}"

cd - > /dev/null