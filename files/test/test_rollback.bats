export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../helpers/rollback.sh'
    load 'testing_utils.sh'
    run_only_test "7"
    setup_tg_env
}

teardown() {
    teardown_tg_env
}

@test "Script is runnable" {
    run rollback.sh
}

@test "New Providers" {
    setup_existing_provider
    setup_new_provider

    run get_new_providers "$TESTING_TMP_DIR"
    assert_output -p "registry.terraform.io/hashicorp/random"
}

@test "No New Providers" {
    setup_existing_provider

    run get_new_providers "$TESTING_TMP_DIR"
    assert_output -p ''
}


@test "New Resources" {
    setup_existing_provider
    setup_new_provider
    
    new_providers=$(get_new_providers "$TESTING_TMP_DIR")

    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve

    expected="$(jq -n '["random_id.test"]')"
    run get_new_providers_resources "$TESTING_TMP_DIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "No New Resources" {
    setup_existing_provider

    cat << EOF > $TESTING_TMP_DIR/new_provider.tf

provider "random" {}

EOF
    new_providers=$(get_new_providers "$TESTING_TMP_DIR")

    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve

    expected="$(jq -n '[]')"
    run get_new_providers_resources "$TESTING_TMP_DIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "Add New Providers" {
    source "./mock_aws_cmds.sh"
    setup_existing_provider
    setup_new_provider

    export ACCOUNT=dev-account
    export TARGET_PATH="files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo"

    pr_queue=$(jq -n \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH '
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
                            ($account):{
                                "Status": "RUNNING",
                                "Dependencies":[],
                                "Stack":{
                                    ($path): {
                                        "Status": "RUNNING",
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
    
    expected=$(jq -n \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH '
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
                            ($account):{
                                "Status": "RUNNING",
                                "Dependencies":[],
                                "Stack":{
                                    ($path): {
                                        "Status": "RUNNING",
                                        "Dependencies":[],
                                        "NewProviders": ["registry.terraform.io/hashicorp/random"]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')

    run update_pr_queue_with_new_providers "$pr_queue" "$TESTING_TMP_DIR"
    assert_output -p "$expected"
}

@test "Add No New Providers" {
    source "./mock_aws_cmds.sh"
    setup_existing_provider

    export ACCOUNT=dev-account
    export TARGET_PATH="files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo"

    pr_queue=$(jq -n \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH '
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
                            ($account):{
                                "Status": "RUNNING",
                                "Dependencies":[],
                                "Stack":{
                                    ($path): {
                                        "Status": "RUNNING",
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
    
    expected=$(jq -n \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH '
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
                            ($account):{
                                "Status": "RUNNING",
                                "Dependencies":[],
                                "Stack":{
                                    ($path): {
                                        "Status": "RUNNING",
                                        "Dependencies":[],
                                        "NewProviders": []
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')

    run update_pr_queue_with_new_providers "$pr_queue" "$TESTING_TMP_DIR"
    assert_output -p "$expected"
}

@test "Add New Resources" {
    source "./mock_aws_cmds.sh"
    setup_existing_provider
    setup_new_provider

    export ACCOUNT=dev-account
    export TARGET_PATH="files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo"
    
    new_providers=$(get_new_providers "$TESTING_TMP_DIR")
    pr_queue=$(add_new_providers "$pr_queue" "${new_providers[*]}")

    # applies new providers and adds new provider resources to tfstate
    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve
    
    expected=$(jq -n \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH '
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
                            ($account):{
                                "Status": "RUNNING",
                                "Dependencies":[],
                                "Stack":{
                                    ($path): {
                                        "Status": "RUNNING",
                                        "Dependencies":[],
                                        "NewProviders": ["registry.terraform.io/hashicorp/random"],
                                        "NewResources": ["random_id.test"]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ')

    run update_pr_queue_with_new_resources "$pr_queue" "$TESTING_TMP_DIR"
    assert_output -p "$expected"
}