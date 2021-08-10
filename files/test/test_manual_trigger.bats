export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../utils.sh'
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
    export CODEBUILD_INITIATOR="user"

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




# #TODO: Add commit queue/inprogress structure
# # Add $RELEASE_CHANGES
# # As new commits come in for inprogress PR: add commit to PR commit queue
# # if $RELEASE_CHANGES or REFRESH_STACK_ON_COMMIT is true: grab latest commit
# # if 
