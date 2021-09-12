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

	log "Cloning Github repo to test file's shared tmp directory" "INFO"
	clone_testing_repo $clone_url $BATS_FILE_TMPDIR
}

setup_test_case_repo() {
	export TEST_CASE_REPO_DIR="$BATS_TEST_TMPDIR/test-repo"
	log "Cloning local template Github repo to test case tmp dir: $TEST_CASE_REPO_DIR" "INFO"
	clone_testing_repo $BATS_FILE_TMPDIR $TEST_CASE_REPO_DIR
	cd "$TEST_CASE_REPO_DIR"
}