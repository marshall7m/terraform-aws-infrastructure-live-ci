#test vars
TERRAGRUNT_WORKING_DIR="../../../infrastructure-live-testing-template/infrastructure-live"
cd $TERRAGRUNT_WORKING_DIR
TERRAGRUNT_WORKING_DIR="./"
ACCOUNT_PARENT_PATHS="dev-account"

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="DEBUG"

log() {
    local log_message=$1
    local log_priority=$2

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    #log here
    echo "${log_priority} : ${log_message}"
}

ACCOUNT_PARENT_PATHS=(${ACCOUNT_PARENT_PATHS//,/ })
# returns the exitcode instead of the plan output (0=no plan difference, 1=error, 2=detected plan difference)

tg_plan_out=$(terragrunt run-all plan --terragrunt-working-dir $TERRAGRUNT_WORKING_DIR --terragrunt-non-interactive -detailed-exitcode 2>&1)

exitcode=$?
if [ $exitcode -eq 1 ]; then
    # TODO: Handle directories with to-be-created remote backends once terragrunt issue is resolved: https://github.com/gruntwork-io/terragrunt/issues/1747
    # see if error is related to remote backend state not being initialized
    if [ ${#new_remote_state} -ne 0 ]; then
        log "Directories with new backends:" "DEBUG"
        log "${new_remote_state[*]}" "DEBUG"
    else
        log "Command Output:" "INFO"
        log "$tg_plan_out" "INFO"
        exit 1
    fi
fi

# Get absolute paths of directories that terragrunt detected a difference between their tf state and their cfg
# use (\n|\s|\t)+ since output format may differ between terragrunt versions
# use grep for single line parsing to workaround lookbehind fixed width constraint
diff_paths=($(echo "$tg_plan_out" | pcregrep -M 'exit\s+status\s+2(\n|\s|\t)+prefix=\[(.+)?(?=\])' | grep -oP '(?<=prefix=\[).+?(?=\])'))

if [ ${#diff_paths[@]} -ne 0 ]; then
    log "Directories with difference in terraform plan:" "DEBUG"
    log "${diff_paths[*]}" "DEBUG"
else
    log "Detected no directories with differences in terraform plan" "ERROR"
    log "Command Output:" "DEBUG"
    log "$tg_plan_out" "DEBUG"
    exit 1
fi

# terragrunt run-all plan run order
stack=$( echo $tg_plan_out | grep -oP '=>\sModule\K.+?(?=\))' )
log "Raw Stack: $stack" "DEBUG"

run_order=$(jq -n '{}')
git_root=$(git rev-parse --show-toplevel)

while read -r line; do
    log "Stack Layer: $(printf \n\t%s\n "$line")" "DEBUG"
    parent=$( echo "$line" | grep -Po '.+?(?=\s\(excluded:)' | xargs realpath -e --relative-to="$git_root" )
    deps=$( echo "$line" | grep -Po 'dependencies:\s+\[\K.+?(?=\])' | grep -Po '.+?(?=,\s|$)' | xargs realpath -e --relative-to="$git_root" )
    
    log "Parent: ${parent}" "DEBUG"
    log "Dependencies: ${deps}" "DEBUG"    

    if [[ " ${diff_paths[@]} " =~ " $parent " ]]; then
        run_order=$( echo $run_order | jq --arg parent "$parent" --arg deps "$deps" '.[$parent] += try [$deps | split(", ")] // []' )
    fi
done <<< "$stack"

echo ${run_order}

exit 1 
declare -A parsed_stack

# gets absolute path to the root of git repo

# filters out target directories that didn't have a difference in terraform plan
for i in $(seq 0 $(( ${#modules[@]} - 1 ))); do
    if [[ " ${diff_paths[@]} " =~ " ${modules[i]} " ]]; then
        # for every directory addded to parsed_stack, only add the git root directory's relative path to the directory
        # Reason is for path portability (absolute paths will differ between instances)
        if [ "${deps[i]}" == "[]" ]; then
            parsed_stack[$(realpath -e --relative-to="$git_root" "${modules[i]}")]+=""
        else 
            parsed_stack[$(realpath -e --relative-to="$git_root" "${modules[i]}")]+=$(realpath -e --relative-to="$git_root" $( echo "${deps[i]}" | sed 's/[][]//g' ))            
        fi
    fi
done

log "Parsed Stack:" "INFO"
for i in ${!parsed_stack[@]}; do 
    log "parsed_stack[$i] = ${parsed_stack[$i]}" "DEBUG"
done

for i in ${parsed_stack[*]}; do 
    log "$i" "DEBUG"
done
exit 1
declare -A run_order

log "Getting run order" "INFO"
# for every directory that is a dependency of another directory
# create copy of keys since bash doesn't allow deletion of for loop's list elements within for loop
parent_keys=("${!parsed_stack[@]}")
for key in "${parsed_stack[*]}"; do
    for sub_key in "${parent_keys[@]}"; do
        if [ "$key" != "$sub_key" ]; then
            log "" "DEBUG"
            log "Checking if directory: ${key}" "DEBUG"
            log "is a direct dependency of: ${sub_key}" "DEBUG"
            log "Dependency List:" "DEBUG"
            log "${parsed_stack[$sub_key]}" "DEBUG"
            # if directory is in a dependency list
            if [[ " ${parsed_stack[$sub_key]} " =~ " $key " ]] ; then
                log "${key} is a dependency of ${sub_key}" "DEBUG"
                #add directory's dependencies to the front of list
                run_order["$sub_key"]=$(echo "${parsed_stack[$key]} ${parsed_stack[$sub_key]}")
            fi
        fi
    done
done

for key in run_order[@]; do
    if [[ " ${run_order[*]} " =~ " $key " ]]; then
        pop 

log "Stack Run Order:" "DEBUG"
for i in ${!run_order[@]}; do 
    log "run_order[$i] = ${run_order[$i]}" "DEBUG"
done

log "Creating Step Function Input" "INFO"
sf_input=$(jq -n '{}')

for parent_dir in "${ACCOUNT_PARENT_PATHS[@]}"; do
    for key in "${!run_order[@]}"; do
        log "Run Order Key: ${key}" "DEBUG"
        log "Parent Directory: ${parent_dir}" "DEBUG"
        rel_path=$(realpath -e --relative-to=$key $parent_dir 2>&1 >/dev/null)
        exitcode=$?
        if [ $exitcode -ne 1 ]; then
            # adds `key` terragrunt directory to the end of the run order
            order="${run_order[$key]} $key"
            log "Appending the following run order:" "DEBUG"
            log "${order}" "DEBUG"
            sf_input=$( echo $sf_input | jq --arg order "$order" --arg parent_dir "$parent_dir" '.[$parent_dir].RunOrder += [$order | split(" ")]' )
        else
            log "Terragrunt dir: ${key} is not a child dir of: ${parent_dir}" "DEBUG"
            log "Error:" "DEBUG"
            log "$rel_path" "DEBUG"
        fi
    done
done

# add PR to CodeBuild source version parameter for quicker downloads since CodeBuild will only have to download the PR instead of entire git repo
sf_input=$( echo $sf_input | jq \
    --arg source_version "$GIT_SOURCE_VERSION" \
    --arg rollback_source_version "$GIT_ROLLBACK_SOURCE_VERSION" \
    '. + {"source_version": $source_version, "rollback_source_version": $rollback_source_version}')
log "Step Function Input:" "INFO"
log "${sf_input}" "INFO"