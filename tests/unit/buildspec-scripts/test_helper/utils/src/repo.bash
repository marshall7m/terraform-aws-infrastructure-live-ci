#!/bin/bash
setup_test_file_repo() {
	local clone_url=$1

	export BATS_FILE_TMPDIR=$(mktemp -d)
	log "BATS_FILE_TMPDIR: $BATS_FILE_TMPDIR" "DEBUG"

	log "Cloning Github repo to test file's shared tmp directory" "INFO"
	clone_testing_repo $clone_url $BATS_FILE_TMPDIR
}

setup_test_case_repo() {
	export TEST_CASE_REPO_DIR="$BATS_TEST_TMPDIR/test-repo"
	log "Cloning local template Github repo to test case tmp dir: $TEST_CASE_REPO_DIR" "INFO"
	clone_testing_repo $BATS_FILE_TMPDIR $TEST_CASE_REPO_DIR
	cd "$TEST_CASE_REPO_DIR"
}

create_testing_repo_mock_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	# create mock executions/accounts/commits tables with finished status
}

parse_tg_path_args() {
	while (( "$#" )); do
		case "$1" in
			--path)
				if [ -n "$2" ]; then
					tg_dir="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
			;;
			--new_provider_resource)
				new_provider_resource=true
			;;
			*)
				echo "Unknown Option: $1"
				exit 1
			;;
		esac
	done
}

checkout_test_case_branch() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	export TESTING_HEAD_REF="test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
	
	log "Creating testing branch: $TESTING_HEAD_REF" "INFO"
	git checkout -B "$TESTING_HEAD_REF"
}

modify_tg_path() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	parse_tg_path_args "$@"

	# get terraform source dir from .terragrunt-cache/
	tf_dir=$(terragrunt terragrunt-info --terragrunt-working-dir "$tg_dir" | jq '.WorkingDir' | tr -d '"')
	
	log "Terraform dir: $tf_dir" "DEBUG"
	
	if [ -n "$new_provider_resource" ]; then
		log "Adding new provider resource" "INFO"
		create_new_provider_resource "$tf_dir"
	else
		log "Adding random terraform output" "INFO"
		create_random_output "$tf_dir"
	fi
}

add_test_case_pr_to_queue() {
	results=$(query """
	INSERT INTO pr_queue (
        pr_id,
        status,
        base_ref,
		head_ref
	)
	VALUES (
		11,
		'waiting',
		'$TESTING_BASE_REF',
		'$TESTING_HEAD_REF'
	)
	RETURNING *;
	""")
	
	log "Results:" "DEBUG"
	log "$results" "DEBUG"
}

add_test_case_head_commit_to_queue() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	if [ -z "$TEST_CASE_REPO_DIR" ]; then
		log "Test case repo directory was not set" "ERROR"
		exit 1
	else
		cd "$TEST_CASE_REPO_DIR"
	fi

	log "Adding testing changes to branch: $(git rev-parse --abbrev-ref HEAD)" "INFO"

	if [ $(git status --short | wc -l) == 0 ]; then
		log "Nothing to commit -- creating dummy file to allow git to create a new commit" "DEBUG"
		touch dummy.txt
	fi

	git add "$(git rev-parse --show-toplevel)/"
	
	git commit -m $TESTING_HEAD_REF
	export TESTING_COMMIT_ID=$(git log --pretty=format:'%H' -n 1)

	log "Adding testing commit to queue" "INFO"

	results=$(query """
	INSERT INTO commit_queue (
		commit_id,
        pr_id,
        status,
        is_rollback
	)
	VALUES (
		'$TESTING_COMMIT_ID',
		11,
		'waiting',
		false
	)
	RETURNING *;
	""")

	log "Results:" "DEBUG"
	log "$results" "DEBUG"
}

teardown_tmp_dir() {
  if [ $BATS_TEST_COMPLETED ]; then
    rm -rf $BATS_TEST_TMPDIR
  else
    echo "Did not delete $BATS_TEST_TMPDIR, as test failed"
  fi
}

create_new_provider_resource() {
	local tf_dir=$1

	testing_id=$(openssl rand -base64 10 | tr -dc A-Za-z0-9)

	declare -A testing_providers
	testing_providers["registry.terraform.io/hashicorp/null"]=$(cat << EOM
	provider "null" {}

	resource "null_resource" "test_$testing_id" {}
EOM
	)
	testing_providers["registry.terraform.io/hashicorp/random"]=$(cat << EOM
	provider "random" {}

	resource "random_id" "test_$testing_id" {
		byte_length = 8
	}
EOM
	)

	log "Getting Terragrunt file providers" "INFO"
	cfg_providers=$(terragrunt providers --terragrunt-working-dir $tf_dir 2>/dev/null | grep -oP '─\sprovider\[\K.+(?=\])' | sort -u)
	log "Providers: $(printf "\n%s" "${cfg_providers[@]}")" "DEBUG"

	log "Getting testing providers that are not in $tf_dir" "INFO"
	out_file="$tf_dir/$testing_id.tf"
	for provider in "${!testing_providers[@]}"; do
		if [[ ! " ${cfg_providers[@]} " =~ " ${provider} " ]]; then
			log "Testing Provider: $provider" "DEBUG"
			log "Adding config:" "DEBUG"
			cfg="${testing_providers[$provider]}"
			log "$cfg" "DEBUG"
			echo "$cfg" > "$out_file"
			exit 0
		fi
	done
	log "Filepath: $out_file" "DEBUG"
}

create_random_output() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local tf_dir=$1
	out_file="$tf_dir/$(openssl rand -base64 10 | tr -dc A-Za-z0-9).tf"
	log "Filepath: $out_file" "DEBUG"

	cat << EOF > "$out_file"
output "test_case_$BATS_TEST_NUMBER" {
	value = "test"
}
EOF
}

clone_testing_repo() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	local clone_url=$1
	local clone_destination=$2

	local_clone_git=$clone_destination/.git

	if [ ! -d $local_clone_git ]; then
		git clone "$clone_url" "$clone_destination"
	else
		log ".git already exists in clone destination" "INFO"
	fi
}