#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../test-helper/load.bash"

load "${BATS_TEST_DIRNAME}/../../node_modules/bash-utils/load.bash"
load "${BATS_TEST_DIRNAME}/../../node_modules/bats-utils/load.bash"

load "${BATS_TEST_DIRNAME}/../../node_modules/bats-support/load.bash"
load "${BATS_TEST_DIRNAME}/../../node_modules/bats-assert/load.bash"

load "${BATS_TEST_DIRNAME}/../../node_modules/psql-utils/load.bash"

#TODO setup test repo with remote s3 backend
setup_file() {
    export script_logging_level="INFO"

    log "FUNCNAME=$FUNCNAME" "DEBUG"

    load 'common_setup.bash'
    _common_setup

    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"

    log "Applying Terragrunt configurations within test repo's base branch" "INFO"
    # configures the local parent directory to store tf-state files given the repo's parent terragrunt.hcl file
    # includes the following local backend path that child cfg files inherit: "$TESTING_LOCAL_PARENT_TF_STATE_DIR/${path_relative_to_include()}/terraform.tfstate"
    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$TEST_FILE_REPO_DIR/tf-state"
    terragrunt run-all apply --terragrunt-working-dir "$TEST_FILE_REPO_DIR/directory_dependency/dev-account"  --terragrunt-non-interactive -auto-approve 
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    log "Destroying test file's base terragrunt resources" "INFO"
    terragrunt run-all destroy --terragrunt-working-dir "$TEST_FILE_REPO_DIR/directory_dependency/dev-account"  --terragrunt-non-interactive -auto-approve 
    teardown_test_file_tmp_dir
}

setup() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    run_only_test 1

    log "Creating test case repo" "INFO"
    setup_test_case_repo

    log "Tracking branches that use Terragrunt commands within test case" "INFO"
    setup_terragrunt_branch_tracking
    
    log "Changing into test case repo directory" "DEBUG"
    # cd into test case repo dir since Codebuild will initially cd into it's source repo root directory
    cd "$TEST_CASE_REPO_DIR"
}

teardown() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    clear_metadb_tables
    teardown_tf_state
    teardown_test_case_tmp_dir
}


@test "successful deployment" {

    target_commit=$(bash mock_commit.bash \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$(jq -n '
        [
            {
                "apply_changes": false,
                "create_provider_resource": false,
                "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/foo"
            }
        ]')" \
        --head-ref "$target_head_ref"
    )

    log "Creating testing PR" "INFO"
    pr_id=$(cd "$TEST_CASE_REPO_DIR" && gh pr create \
        --title "bats-test-case-$BATS_TEST_NUMBER" \
        --body "Testing Terragrunt changes with no dependencies" \
        --base "master" \
        --repo "github.com/marshall7m/infrastructure-live-testing-template"
        | xargs -I {} basename {})
    log "PR ID: $pr_id" "INFO"
    
    # pr_in_queue=false
    # while [ "$pr_in_queue" != true ]; do
    #     sleep 15
    #     pr_in_queue=$(psql -c "SELECT EXISTS(SELECT pr_id FROM pr_queue WHERE pr_id = '$pr_id')")
    # done

    # log "Starting trigger sf codebuild manually" "INFO"
    # aws codebuild start-build --project-name "$TRIGGER_SF_CODEBUILD_ARN"

    # """

    # Setup:
    #     - Terragrunt apply test repo's master branch
    
    # Test Process
    # 1. Create PR
    # 2. Push terragrunt changes
    # 3. Manually call trigger_sf Codebuild | Mock CW event with SF execution response
    # 4. Automate approval request acceptance
    # 5. Run assertions

    # Assertion Components:

    # AWS Services were called:
    #     - Codebuild PR queue:
    #         - Assert success
    #         - Assert PR was added to pr_queue
    #     - Codebuild trigger_sf:
    #         - Assert success
    #         - Assert PR's head commit was added to commit_queue
    #         - Assert PR's modified cfg_paths were added to executions
    #         - Assert Step Function was called for each target cfg_path
    #     - Step Function:
    #         - Assert Step Function executions associated with commit changes cfg_paths are running
    #         - Assert associated approval voter received approval request
    #         - Assert approval was added to execution's approval_count
    #         - Once approval_count reaches min_approval_count, assert deploy task is running
    #         - Assert deploy changes were added
    #         - Once execution is done, assert trigger_sf CodeBuild was triggered
    
    # Teardown:
    #     - Terragrunt destroy PR terragrunt changes
    #     - Delete PR
    #     - Clear metadb tables
    # """
}
