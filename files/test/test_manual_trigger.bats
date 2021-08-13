export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

export CODEBUILD_INITIATOR="user"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../helpers/trigger_sf_utils.sh'
    load 'testing_utils.sh'
}

@test "script is runnable" {
    run trigger_sf_utils.sh
}

@test "PR not in Progress" {
    pr_queue=$(jq -n '
        {
            "Queue": [
                {
                    "ID": 2,
                    "BaseRef": "master",
                    "HeadRef": "feature-2"
                }
            ],
            "InProgress": {}
        }
    ')
    run pr_in_progress "$pr_queue"
    [ "$status" -eq 1 ]
}

@test "PR in Progress" {
    pr_queue=$(jq -n '
        {
            "InProgress": {
                "ID": 1,
                "BaseRef": "master",
                "HeadRef": "feature-1"
            }
        }
    ')
    run pr_in_progress "$pr_queue"
    [ "$status" -eq 0 ]
}


@test "Deployment in Progress Check" {
    pr_queue=$(jq -n '
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
                                "Status": "RUNNING",
                                "Dependencies":[
                                    "security-account"
                                ],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Status": "SUCCESS",
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
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

    run deploy_stack_in_progress "$pr_queue"

    assert_output true
}

@test "Deployment NOT in Progress Check" {
    pr_queue=$(jq -n '
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
                                "Dependencies":[
                                    "security-account"
                                ],
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

    run deploy_stack_in_progress "$pr_queue"

    assert_output false
}

@test "Override Pull Request Queue" {
    export CODEBUILD_INITIATOR="user"
    export DEPLOY_PULL_REQUEST_ID="3"
    pr_queue=$(jq -n '
        {
            "Queue": [
                {
                    "ID": "2",
                    "BaseRef": "master",
                    "HeadRef": "feature-2"
                },
                {
                    "ID": "3",
                    "BaseRef": "master",
                    "HeadRef": "feature-3"
                }
            ],
            "InProgress": {}
        }
    ')
    
    expected=$(jq -n '
        {
            "Queue": [
                {
                    "ID": "2",
                    "BaseRef": "master",
                    "HeadRef": "feature-2"
                }
            ],
            "InProgress": {
                "ID": "3",
                "BaseRef": "master",
                "HeadRef": "feature-3"
            }
        }
    ')
    run update_pr_queue_with_next_pr "$pr_queue" 2>/dev/null
    assert_output -p "$expected"
}

@test "Pull Next Pull Request in Queue" {

    pr_queue=$(jq -n '
        {
            "Queue": [
                {
                    "ID": "2",
                    "BaseRef": "master",
                    "HeadRef": "feature-2"
                },
                {
                    "ID": "3",
                    "BaseRef": "master",
                    "HeadRef": "feature-3"
                }
            ],
            "InProgress": {}
        }
    ')
    
    expected=$(jq -n '
        {
            "Queue": [
                {
                    "ID": "3",
                    "BaseRef": "master",
                    "HeadRef": "feature-3"
                }
            ],
            "InProgress": {
                "ID": "2",
                "BaseRef": "master",
                "HeadRef": "feature-2"
            }
        }
    ')
    run update_pr_queue_with_next_pr "$pr_queue"
    assert_output -p "$expected"
}

@test "Create Pull Request Commit Stack" {

    setup_test_env \
        --clone-url "https://github.com/marshall7m/infrastructure-live-testing-template.git" \
        --clone-destination "./tmp" \
        --terragrunt-working-dir "./tmp/directory_dependency" \
        --modify "./tmp/directory_dependency/security-account/us-west-2/env-one/baz" \
        --modify "./tmp/directory_dependency/dev-account/us-west-2/env-one/doo" \
        --modify "./tmp/directory_dependency/dev-account/us-west-2/env-one/foo" \
        # --skip-terraform-state-setup


    run update_pr_queue_with_new_commit_stack "2" "$pr_queue"
}


@test "Get Deploy Paths" {
    
    deploy_stack=$(jq -n '
        {
            "foo": {
                "Dependencies": [],
                "Stack": {
                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo": [],
                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo": []
                }
            }
        }
    ')

    expected=$(jq -n '
        {

        }
    ')
    run get_deploy_paths $deploy_stack
    
    assert_output "$expected" 
}

@test "Rollback Needed" {
    pr_queue=$(jq -n '
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
                                "Dependencies":[
                                    "security-account"
                                ],
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

    run needs_rollback "$pr_queue"

    assert_output true
}

@test "Rollback NOT Needed" {
    pr_queue=$(jq -n '
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

    run needs_rollback "$pr_queue"

    assert_output false
}

@test "Commit Queue is Empty" {

    pr_queue=$(jq -n '
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
    run commit_queue_is_empty "$pr_queue"

    assert_output true
}

@test "Commit Queue is NOT Empty" {

    pr_queue=$(jq -n '
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
    run commit_queue_is_empty "$pr_queue"

    assert_output false
}

@test "Dequeue Commit" {
    pr_queue=$(jq -n '
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

    run update_pr_queue_with_next_commit "$pr_queue"
    assert_output -p "$expected"
}