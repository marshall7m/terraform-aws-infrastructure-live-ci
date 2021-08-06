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

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
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

clone_testing_repo() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	local clone_url=$1
	local clone_destination=$2

	local_clone_git=$clone_destination/.git

	if [ ! -d $local_clone_git ]; then
		git clone "$clone_url" "$clone_destination"
	fi

	log "Changing Directory to test repo" "DEBUG"
	cd "$clone_destination"
}


setup_test_env() {

	parse_args "$@"

	log "Modify list: ${modify_paths[*]}"  "DEBUG"
	clone_testing_repo $clone_url $clone_destination

	if [ -z "$SKIP_TERRAFORM_TESTING_STATE" ]; then
		log "Applying all dirs" "DEBUG"

		apply_out=$(terragrunt run-all apply \
			--terragrunt-non-interactive \
			--terragrunt-include-external-dependencies \
			--terragrunt-working-dir "$terragrunt_working_dir" \
			-auto-approve \
			2>&1
		)

		if [ "${#modify_paths[@]}" -eq 0 ]; then
			log "No --modify dirs were defined -- All Terragrunt directory plans will be up-to-date" "INFO"
		else
			for dir in "${modify_paths[@]}"; do
			
				log "Modifying state for directory: $dir" "DEBUG"
				terragrunt destroy \
					--terragrunt-strict-include \
					--terragrunt-non-interactive \
					--terragrunt-ignore-external-dependencies \
					--terragrunt-working-dir "$dir" \
					-auto-approve
			done
		fi
	else 
		log "Skipping testing repo setup" "INFO"
	fi
}


if [ -n "$MOCK_GIT_CMDS" ]; then
    source mock_git_cmds.sh
fi

if [ -n "$MOCK_AWS_CMDS" ]; then
    source mock_aws_cmds.sh
fi