export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

export CODEBUILD_INITIATOR="user"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../helpers/utils.sh'
    load 'testing_utils.sh'
}

@test "script is runnable" {
    run utils.sh
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

    pr_queue=$(jq -n '
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

    get_approval_mapping() {
        echo $(jq -n '
            {
                "Dev-Env": {
                    "Name": "Testing-Env",
                    "Paths": ["./tmp/directory_dependency/dev-account"],
                    "Dependencies": ["./tmp/directory_dependency/security-account"],
                    "Voters": ["admin-testing-user"],
                    "ApprovalCountRequired": 2,
                    "RejectionCountRequired": 2
                },
                "Security-Env": {
                    "Name": "Security-Env",
                    "Paths": ["./tmp/directory_dependency/security-account"],
                    "Dependencies": [],
                    "Voters": ["admin-security-user"],
                    "ApprovalCountRequired": 10,
                    "RejectionCountRequired": 2
                }
            }
        ')
    }
    
    expected=$(jq -n '
        {
            "Queue":[
                {
                    "ID":"3",
                    "BaseRef":"master",
                    "HeadRef":"feature-3"
                }
            ],
            "InProgress":{
                "ID":"2",
                "BaseRef":"master",
                "HeadRef":"feature-2",
                "CommitStack":{
                    "1":{
                        "DeployStack":{
                            "./tmp/directory_dependency/dev-account":{
                                "Dependencies":[
                                    "./tmp/directory_dependency/security-account"
                                ],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Dependencies":[]
                                    }
                                }
                            },
                            "./tmp/directory_dependency/security-account":{
                                "Dependencies":[],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/bar":{
                                        "Dependencies":[
                                            "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/baz"
                                        ]
                                    },
                                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/baz":{
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/foo":{
                                        "Dependencies":[
                                            "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/bar"
                                        ]
                                    }
                                }
                            }
                        },
                        "InitialDeployStack":{
                            "./tmp/directory_dependency/dev-account":{
                                "Dependencies":[
                                    "./tmp/directory_dependency/security-account"
                                ],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/doo":{
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/dev-account/us-west-2/env-one/foo":{
                                        "Dependencies":[]
                                    }
                                }
                            },
                            "./tmp/directory_dependency/security-account":{
                                "Dependencies":[],
                                "Stack":{
                                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/bar":{
                                        "Dependencies":[
                                            "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/baz"
                                        ]
                                    },
                                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/baz":{
                                        "Dependencies":[]
                                    },
                                    "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/foo":{
                                        "Dependencies":[
                                            "files/test/tmp/directory_dependency/security-account/us-west-2/env-one/bar"
                                        ]
                                    }
                                }
                            }
                        },
                        "BaseSourceVersion":"MOCK: FUNCNAME=get_git_source_versions",
                        "HeadSourceVersion":"MOCK: FUNCNAME=get_git_source_versions"
                    }
                }
            }
        }
    ')

    run update_pr_queue_with_new_commit_stack "2" "$pr_queue"

    assert_output -p "$expected"
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