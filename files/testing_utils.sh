assertEquals() {
    msg=$1 
    expected=$2
    actual=$3
    echo "$msg: "
    if [ "$expected" != "$actual" ]; then
        log "ASSERTION:FAILED EXPECTED=$expected ACTUAL=$actual" "ERROR"
    else
        echo "PASSED"
    fi
}

clone_testing_repo() {
  local clone_url=$1
  local clone_destination=$2

  local_clone_git=$clone_destination/.git

  if [ ! -d $local_clone_git ]; then
    git clone "$clone_url" "$clone_destination"
  fi

  echo "Changing Directory to test repo"
  cd "$clone_destination"
}

create_terraform_testing_state() {
  set -e

  local modify_paths=$1 

  echo "Applying all dirs"
  apply_out=$(terragrunt run-all apply \
    --terragrunt-non-interactive \
    --terragrunt-include-external-dependencies \
    --terragrunt-working-dir "$terragrunt_working_dir" \
    -auto-approve \
    2>&1)
  
  echo "Destroying Target Directory States"
  destroy_out=$(terragrunt run-all destroy \
    --terragrunt-strict-include \
    --terragrunt-non-interactive \
    --terragrunt-working-dir "$terragrunt_working_dir" \
    $( printf -- "--terragrunt-include-dir %s " "${modify_paths[@]}" ) \
    2>&1)
}

setup_test_env() {
  parse_args "$@"
  clone_testing_repo $clone_url $clone_destination
	
  if [ -z "$SKIP_TERRAFORM_TESTING_STATE" ]; then
    create_terraform_testing_state "$modify_paths"
	else 
		log "Skipping testing repo setup" "INFO"
	fi
}

parse_args() {
    modify_paths=()
    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
            --clone-url)
                clone_url="$2"
                shift 
                shift
                ;;
            --clone-destination)
                clone_destination="$2"
                shift 
                shift
                ;;
            --terragrunt-working-dir)
                terragrunt_working_dir="$2"
                shift 
                shift
                ;;
            --modify)
                modify_paths+=("$2")
                shift 
                shift
                ;;
            *)
                echo "Unknown Option: $1"
                exit 1
                ;;
        esac
    done
}


if [ -n "$MOCK_GIT_CMDS" ]; then
    source mock_git_cmds.sh
fi

if [ -n "$MOCK_AWS_CMDS" ]; then
    source mock_aws_cmds.sh
fi