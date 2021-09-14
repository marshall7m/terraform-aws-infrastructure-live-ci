#!/bin/bash

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

setup_test_file_repo() {
	local clone_url=$1

	export BATS_FILE_TMPDIR=$(mktemp -d)
	log "BATS_FILE_TMPDIR: $BATS_FILE_TMPDIR" "DEBUG"

	export TEST_FILE_REPO_DIR="$BATS_FILE_TMPDIR/test-repo"
	log "TEST_FILE_REPO_DIR: $TEST_FILE_REPO_DIR" "DEBUG"

	clone_testing_repo $clone_url $TEST_FILE_REPO_DIR
}

setup_test_file_tf_state() {
	# repo's git root path relative path to terragrunt parent directory
	local terragrunt_root_dir=$1
	if [ -z "$terragrunt_root_dir" ]; then
		log "terragrunt_root_dir is not set" "ERROR"
		exit 1
	elif [ -z "$TEST_FILE_REPO_DIR" ]; then
		log "terragrunt_root_dir is not set" "ERROR"
		exit 1
	fi

	# applies all of repo's terragrunt configurations at test file level
	# test cases can just source from test file directory instead of reapplying terragrunt config for every test case
	export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_FILE_TMPDIR/test-file-repo-tf-state"

	log "Setting up test file tmp repo directory for tfstate" "INFO"
	log "TESTING_LOCAL_PARENT_TF_STATE_DIR: $TESTING_LOCAL_PARENT_TF_STATE_DIR" "DEBUG"

	
	abs_terragrunt_root_dir="$TEST_FILE_REPO_DIR/$terragrunt_root_dir"
	log "Absolute path to Terragrunt parent directory: $abs_terragrunt_root_dir"

	log "Applying all terragrunt repo configurations" "INFO"
	terragrunt run-all apply --terragrunt-working-dir "$abs_terragrunt_root_dir" -auto-approve || exit 1
}

setup_test_case_repo() {
	export TEST_CASE_REPO_DIR="$BATS_TEST_TMPDIR/test-repo"
	log "Cloning local template Github repo to test case tmp dir: $TEST_CASE_REPO_DIR" "INFO"
	clone_testing_repo $TEST_FILE_REPO_DIR $TEST_CASE_REPO_DIR
	cd "$TEST_CASE_REPO_DIR"
}

setup_test_case_tf_state() {
	#creates persistent local tf state for test case repo even when test repo commits are checked out (see test repo's parent terragrunt file generate backend block)
    test_case_tf_state_dir="$BATS_TEST_TMPDIR/test-repo-tf-state"

	log "Copying test file's terraform state file structure to test case repo tmp dir" "INFO"
	cp -rv "$TESTING_LOCAL_PARENT_TF_STATE_DIR" "$test_case_tf_state_dir"

	export TESTING_LOCAL_PARENT_TF_STATE_DIR="$test_case_tf_state_dir"
}