export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

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

@test "Move Pull Request to front of Queue" {
    export CODEBUILD_INITIATOR="user"
    export NEXT_PR_IN_QUEUE="3"

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
                },
                {
                    "ID": "2",
                    "BaseRef": "master",
                    "HeadRef": "feature-2"
                }
            ],
            "InProgress": {}
        }
    ')
    run pr_to_front "$pr_queue" "3"
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
    skip
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

@test "Create Rollback Stack" {
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
    
    run update_pr_queue_with_rollback_stack "$pr_queue"
    assert_output -p "$expected"
}