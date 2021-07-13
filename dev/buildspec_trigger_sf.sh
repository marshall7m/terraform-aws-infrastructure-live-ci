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

# gets absolute path to the root of git repo
git_root=$(git rev-parse --show-toplevel)

# Get git repo root path relative path to the directories that terragrunt detected a difference between their tf state and their cfg
# use (\n|\s|\t)+ since output format may differ between terragrunt versions
# use grep for single line parsing to workaround lookbehind fixed width constraint
diff_paths=($(echo "$tg_plan_out" | pcregrep -M 'exit\s+status\s+2(\n|\s|\t)+prefix=\[(.+)?(?=\])' | grep -oP '(?<=prefix=\[).+?(?=\])' | xargs realpath -e --relative-to="$git_root"))

if [ ${#diff_paths[@]} -ne 0 ]; then
    log "Directories with difference in terraform plan:" "DEBUG"
    log "$(printf "\n\t%s" "${diff_paths[*]}")" "DEBUG"
else
    log "Detected no directories with differences in terraform plan" "ERROR"
    log "Command Output:" "DEBUG"
    log "$tg_plan_out" "DEBUG"
    exit 1
fi

# terragrunt run-all plan run order
stack=$( echo $tg_plan_out | grep -oP '=>\sModule\K.+?(?=\))' )
log "Raw Stack: $(printf "\n\t%s" "$stack")" "DEBUG"

shallow_run_order=$(jq -n '{}')

while read -r line; do
    log "Stack Layer: $(printf "\n\t%s\n" "$line")" "DEBUG"
    parent=$( echo "$line" | grep -Po '.+?(?=\s\(excluded:)' | xargs realpath -e --relative-to="$git_root" )
    deps=$( echo "$line" | grep -Po 'dependencies:\s+\[\K.+?(?=\])' | grep -Po '.+?(?=,\s|$)' | xargs realpath -e --relative-to="$git_root" )
    
    log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"
    log "Dependencies: $(printf "\n\t%s" "${deps}")" "DEBUG"

    if [[ " ${diff_paths[@]} " =~ " ${parent} " ]]; then
        log "Found difference in plan" "DEBUG"
        shallow_run_order=$( echo $shallow_run_order | jq --arg parent "$parent" --arg deps "$deps" '.[$parent] += try [$deps | split("\n") | reverse] // []' )
        log "Run Order:" "DEBUG"
        log "$shallow_run_order" "DEBUG"
    else
        log "Detected no difference in terraform plan for directory: ${parent}" "DEBUG"
    fi
done <<< "$stack"

echo "shallow"
echo ${shallow_run_order}

run_order=$(echo ${shallow_run_order} | jq '([.. | .[]? | strings] | unique) as $uniq_deps 
    | . as $origin 
    | with_entries(select([.key] 
    | inside($uniq_deps) 
    | not)) 
    | map_values(. += $origin[.. | .[]? | strings] | reverse)'
)

echo "run order:"
echo $run_order
exit 1

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