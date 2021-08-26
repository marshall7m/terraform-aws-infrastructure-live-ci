export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../../../files/buildspec-scripts/trigger_sf.sh'
    load 'testing_utils.sh'
    export script_logging_level="DEBUG"
    
    setup_tg_env

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

#TODO Figure out better way to organize tests (put sub func into child dir?)

@test "New Providers" {
    setup_existing_provider
    setup_new_provider

    run get_new_providers "$TESTING_TMP_DIR"
    assert_failure
    assert_output -p "registry.terraform.io/hashicorp/random"
}

@test "No New Providers" {
    setup_existing_provider

    run get_new_providers "$TESTING_TMP_DIR"
    assert_output -p ''
}

@test "New Resources" {
    setup_existing_provider
    setup_new_provider_with_resource
    setup_terragrunt_apply

    expected="$(jq -n --arg new_resources $new_resources 'try ($new_resources | split(" ")) // []')"
    run get_new_providers_resources "$TESTING_TMP_DIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "No New Resources" {
    setup_existing_provider
    setup_new_provider
    setup_terragrunt_apply
    
    expected="$(jq -n '[]')"
    run get_new_providers_resources "$TESTING_TMP_DIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "Add new providers to stack" {
    setup_existing_provider
    setup_new_provider

    stack=$(jq -n \
    --arg testing_dir $TESTING_TMP_DIR '
    [
        {
            "path": $testing_dir,
            "dependencies": []
        }
    ]')

    declare -a target_paths=("$TESTING_TMP_DIR")
    expected=$(jq -n \
    --arg testing_dir $TESTING_TMP_DIR \
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
    --arg testing_dir $TESTING_TMP_DIR '
    [
        {
            "path": $testing_dir,
            "dependencies": []
        }
    ]')

    declare -a target_paths=("$TESTING_TMP_DIR")
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

@test "Create Pull Request Commit Stack" {
    
    setup_test_env \
        --clone-url "https://github.com/marshall7m/infrastructure-live-testing-template.git" \
        --clone-destination "$TESTING_TMP_DIR" \
        --terragrunt-working-dir "$TESTING_TMP_DIR/directory_dependency" \
        --modify "$TESTING_TMP_DIR/directory_dependency/security-account/us-west-2/env-one/baz" \
        --modify "$TESTING_TMP_DIR/directory_dependency/dev-account/us-west-2/env-one/doo" \
        --modify "$TESTING_TMP_DIR/directory_dependency/dev-account/us-west-2/env-one/foo" \
        # --skip-terraform-state-setup
    
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

    run update_executions_with_new_commit_stack "$executions" "$account_queue" "$commit_item"
    assert_output "$expected"
}


@test "Get Deploy Paths with initial multi-account stack" {
    
    deploy_stack=$(jq -n '
        {
            "dev-account":{
                "Status": "Waiting",
                "Dependencies":[
                    "security-account"
                ],
                "Stack":{
                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                        "Status": "WAITING",
                        "Dependencies":[]
                    },
                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                        "Status": "WAITING",
                        "Dependencies":["files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo"]
                    }
                }
            },
            "security-account":{
                "Status": "WAITING",
                "Dependencies":[],
                "Stack":{
                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/doo":{
                        "Status": "WAITING",
                        "Dependencies":[]
                    },
                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/foo":{
                        "Status": "WAITING",
                        "Dependencies":["files/test/tmp/directory_dependency/security-account/us-west-2/env-one/doo"]
                    }
                }
            }
        }
    ')

    expected=$(jq -n '
        [
            "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/doo"
        ]
    ')

    run get_deploy_paths "$deploy_stack"
    
    assert_output -p "$expected"
}

@test "Get Deploy Paths with dependency path equals success" {
    
    deploy_stack=$(jq -n '
        {
            "dev-account":{
                "Status": "RUNNING",
                "Dependencies":[],
                "Stack":{
                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                        "Status": "SUCCESS",
                        "Dependencies":[]
                    },
                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                        "Status": "WAITING",
                        "Dependencies":["files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo"]
                    }
                }
            }
        }
    ')

    expected=$(jq -n '
        [
            "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo"
        ]
    ')
    
    run get_deploy_paths "$deploy_stack"
    
    assert_output -p "$expected"
}

@test "Rollback Needed" {
    executions=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "InProgress": {
                        "DeployStack": {
                            "dev-account":{
                                "Status": "FAILURE",
                                "Dependencies":[],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Status": "SUCCESS",
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Status": "FAILURE",
                                        "Dependencies":[]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')

    run needs_rollback "$executions"

    assert_output true
}

@test "Rollback NOT Needed" {
    executions=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "InProgress": {
                        "ID": "test-commit-id",
                        "DeployStack": {
                            "dev-account":{
                                "Status": "SUCCESS",
                                "Dependencies":[
                                    "security-account"
                                ],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Status": "SUCCESS",
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Status": "SUCCESS",
                                        "Dependencies":[]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')

    run needs_rollback "$executions"

    assert_output false
}

@test "Commit Queue is Empty" {

    executions=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "Queue": [],
                    "InProgress": {}
                }
            }
        }
    ')
    run commit_queue_is_empty "$executions"

    assert_output true
}

@test "Commit Queue is NOT Empty" {

    executions=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "Queue": [
                        {
                            "ID": "test-commit-id"
                        }
                    ],
                    "InProgress": {}
                }
            }
        }
    ')
    run commit_queue_is_empty "$executions"

    assert_output false
}

@test "Dequeue Commit" {
    executions=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "Queue": [
                        {
                            "ID": "test-commit-id"
                        }
                    ],
                    "InProgress": {}
                }
            }
        }
    ')

    expected=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "Queue": [],
                    "InProgress": {
                        "ID": "test-commit-id"
                    }
                }
            }
        }
    ')

    run update_executions_with_next_commit "$executions"
    assert_output -p "$expected"
}

@test "Create Rollback Stack" {
    executions=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "InProgress": {
                        "ID": "test-commit-id",
                        "DeployStack": {
                            "dev-account":{
                                "Status": "FAILED",
                                "Dependencies":[],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Status": "SUCCESS",
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Status": "FAILED",
                                        "Dependencies":[]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')

    expected=$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2",
                "CommitStack": {
                    "InProgress": {
                        "ID": "test-commit-id",
                        "DeployStack": {
                            "dev-account":{
                                "Status": "FAILED",
                                "Dependencies":[],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Status": "SUCCESS",
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Status": "FAILED",
                                        "Dependencies":[]
                                    }
                                }
                            }
                        },
                        "RollbackStack": {
                            "dev-account":{
                                "Status": "Waiting",
                                "Dependencies":[],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Status": "Waiting",
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Status": "Waiting",
                                        "Dependencies":[]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')
    
    run update_executions_with_rollback_stack "$executions"
    assert_output -p "$expected"
}