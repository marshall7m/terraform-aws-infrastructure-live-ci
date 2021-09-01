export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../../../files/buildspec-scripts/trigger_sf.sh'
    load 'testing_utils.sh'
    export script_logging_level="DEBUG"
    
    setup_testing_env

    run_only_test "12"
}

teardown() {
    teardown_tg_env
}

@test "Execution(s) not in progress" {

    executions=$(jq -n '[
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "SUCCESS"
        },
        {
            "path": "test-path-2/",
            "execution_id": "test-id-2",
            "deployment_type": "Deploy",
            "status": "SUCCESS"
        }
    ]')

    run executions_in_progress "$executions"
    [ "$status" -eq 1 ]
}

@test "Execution(s) in progress" {
    executions=$(jq -n '[
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "RUNNING"
        },
        {
            "path": "test-path-2/",
            "execution_id": "test-id-2",
            "deployment_type": "Deploy",
            "status": "SUCCESS"
        }
    ]')
    run executions_in_progress "$executions"
    [ "$status" -eq 0 ]
}

@test "Update execution status" {

    execution_id="test-id-A"
    executions=$(jq -n \
    --arg execution_id $execution_id '[
        {
            "path": "test-path",
            "execution_id": $execution_id,
            "deployment_type": "Deploy",
            "status": "RUNNING"
        }
    ]')

    expected=$(jq -n \
    --arg execution_id $execution_id '[
        {
            "path": "test-path",
            "execution_id": $execution_id,
            "deployment_type": "Deploy",
            "status": "SUCCESS"
        }
    ]')

    run update_execution_status "$executions" "$execution_id" "SUCCESS"
    assert_output -p "$expected"
}

@test "Add new provider resources to execution's record" {
    get_new_providers_resources() {
        echo "$(jq -n '["test_resource.this"]')"
    }

    deployed_path="test-path"
    new_resources=$(get_new_providers_resources)
    execution_id="test-id-A"

    executions=$(jq -n \
    --arg execution_id $execution_id \
    --arg deployed_path $deployed_path '[
        {
            "path": $deployed_path,
            "execution_id": $execution_id,
            "deployment_type": "Deploy",
            "status": "RUNNING",
            "new_providers": ["test/provider"]
        },
        {
            "path": $deployed_path,
            "execution_id": "test-id-B",
            "deployment_type": "Deploy",
            "status": "RUNNING"
        }
    ]')

    expected=$(jq -n \
    --arg execution_id $execution_id \
    --arg deployed_path $deployed_path \
    --arg new_resources "$new_resources" '
    ($new_resources | fromjson) as $new_resources
    | [
        {
            "path": $deployed_path,
            "execution_id": $execution_id,
            "deployment_type": "Deploy",
            "status": "RUNNING",
            "new_providers": ["test/provider"],
            "new_resources": ["test_resource.this"]
        },
        {
            "path": $deployed_path,
            "execution_id": "test-id-B",
            "deployment_type": "Deploy",
            "status": "RUNNING"
        }
    ]')

    run update_execution_with_new_resources "$executions" "$execution_id" "$deployed_path"
    assert_output -p "$expected"
}

@test "Add rollback commmits to front of repo queue" {
    executions=$(jq -n '
    [
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "RUNNING",
            "commit_id": "commit-1",
            "pr_id": 1,
            "status": "RUNNING",
            "type": "Deploy"
        },
        {
            "path": "test-path-2/",
            "execution_id": "test-id-2",
            "deployment_type": "Deploy",
            "status": "SUCCESS",
            "commit_id": "commit-1",
            "pr_id": 1,
            "status": "FAILED",
            "type": "Deploy",
            "new_resources": ["test_resource.this"]
        }
    ]')

    commit_queue=$(jq -n '
    [
        {
            "commit_id": "commit-1",
            "pr_id": 1,
            "status": "RUNNING",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Deploy"
        },
        {
            "commit_id": "commit-2",
            "pr_id": 2,
            "status": "Waiting",
            "base_ref": "master",
            "head_ref": "feature-2",
            "type": "Deploy"
        }
    ]')

    pr_id=1

    expected=$(jq -n '
    [
        {
            "commit_id": "commit-1",
            "pr_id": 1,
            "status": "Waiting",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Rollback"
        },
        {
            "commit_id": "commit-1",
            "pr_id": 1,
            "status": "RUNNING",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Deploy"
        },
        {
            "commit_id": "commit-2",
            "pr_id": 2,
            "status": "Waiting",
            "base_ref": "master",
            "head_ref": "feature-2",
            "type": "Deploy"
        }
    ]')

    run update_commit_queue_with_rollback_commits "$commit_queue" "$executions" "$pr_id"

    assert_output -p "$expected"

}

@test "New Providers" {
    setup_existing_provider
    setup_new_provider

    run get_new_providers "$BATS_TMPDIR"
    assert_failure
    assert_output -p "registry.terraform.io/hashicorp/random"
}

@test "No New Providers" {
    setup_existing_provider

    run get_new_providers "$BATS_TMPDIR"
    assert_output -p ''
}

@test "New Resources" {
    setup_existing_provider
    setup_new_provider_with_resource
    setup_terragrunt_apply

    expected="$(jq -n --arg new_resources $new_resources 'try ($new_resources | split(" ")) // []')"
    run get_new_providers_resources "$BATS_TMPDIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "No New Resources" {
    setup_existing_provider
    setup_new_provider
    setup_terragrunt_apply
    
    expected="$(jq -n '[]')"
    run get_new_providers_resources "$BATS_TMPDIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "Add new providers to stack" {
    setup_existing_provider
    setup_new_provider

    stack=$(jq -n \
    --arg testing_dir $BATS_TMPDIR '
    [
        {
            "path": $testing_dir,
            "dependencies": []
        }
    ]')

    declare -a target_paths=("$BATS_TMPDIR")
    expected=$(jq -n \
    --arg testing_dir $BATS_TMPDIR \
    --arg new_providers $new_providers '
    (try ($new_providers | split(" ")) // []) as $new_providers
    [
        {
            "path": $testing_dir,
            "dependencies": [],
            "new_providers": $new_providers
        }
    ]')

    run update_stack_with_new_providers "$stack" "$target_paths"
    assert_output -p "$expected"
}

@test "Add No New Providers" {
    setup_existing_provider
    stack=$(jq -n \
    --arg testing_dir $BATS_TMPDIR '
    [
        {
            "path": $testing_dir,
            "dependencies": []
        }
    ]')

    declare -a target_paths=("$BATS_TMPDIR")
    expected="$stack"

    run update_stack_with_new_providers "$stack" "$target_paths"
    assert_output -p "$expected"
}

@test "Pull Next Pull Request in Queue" {

    commit_queue=$(jq -n '
    [
        {
            "commit_id": "commit-3",
            "pr_id": 1,
            "status": "Waiting",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Deploy"
        },
        {
            "commit_id": "commit-2",
            "pr_id": 1,
            "status": "Waiting",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Deploy"
        },
        {
            "commit_id": "commit-1",
            "pr_id": 2,
            "status": "Success",
            "base_ref": "master",
            "head_ref": "feature-2",
            "type": "Deploy"
        }
    ]')

    expected=$(jq -n '
    [
        {
            "commit_id": "commit-3",
            "pr_id": 1,
            "status": "Running",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Deploy"
        },
        {
            "commit_id": "commit-2",
            "pr_id": 1,
            "status": "Waiting",
            "base_ref": "master",
            "head_ref": "feature-1",
            "type": "Deploy"
        },
        {
            "commit_id": "commit-1",
            "pr_id": 2,
            "status": "Success",
            "base_ref": "master",
            "head_ref": "feature-2",
            "type": "Deploy"
        }
    ]')
    run dequeue_commit_from_commit_queue "$commit_queue"
    assert_output -p "$expected"
}

@test "Update executions with deploy commit" {
    
    account_queue=$()
    executions=$(jq -n '
    [
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "RUNNING",
            "commit_id": "commit-1",
            "pr_id": 1,
            "status": "RUNNING",
            "type": "Deploy"
        }
    ]')

    run update_executions_with_new_deploy_stack "$executions" "$account_queue" "$commit_item"
    assert_output "$expected"
}