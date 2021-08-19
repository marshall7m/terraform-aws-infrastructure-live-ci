export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../helpers/queue_utils.sh'
    load 'testing_utils.sh'

    pull_request_id="2"
    export base_ref="master"
    export head_ref="feature-1"
    commit_id="test-commit-id"
    CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"
}

@test "script is runnable" {
    run queue_utils.sh
}

@test "Main Function is runnable" {
    get_event_vars() {
        echo "MOCK: FUNCNAME=$FUNCNAME"
    }
    run queue
    assert_success
}

@test "Add Commit to Queue" {
    pr_queue="$(jq -n \
        --arg pull_request_id "$pull_request_id" \
        --arg base_ref "$base_ref" \
        --arg head_ref "$head_ref" '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": $base_ref,
                "HeadRef": $head_ref,
                "CommitStack": {
                    "Queue": [],
                    "InProgress": {
                        "DeployStack": {}
                    },
                    "Finished": []
                }
            },
            "Finished": []
        }
    ')"
    
    expected="$(jq -n \
        --arg pull_request_id "$pull_request_id" \
        --arg base_ref "$base_ref" \
        --arg head_ref "$head_ref" \
        --arg commit_id "$commit_id" '
        {
            "Queue": [],
            "InProgress": {
                "ID": "2",
                "BaseRef": $base_ref,
                "HeadRef": $head_ref,
                "CommitStack": {
                    "Queue": [
                        {
                            "ID": $commit_id
                        }
                    ],
                    "InProgress": {
                        "DeployStack": {}
                    },
                    "Finished": []
                }
            },
            "Finished": []
        }
    ')"

    run commit_to_queue "$pr_queue" "$commit_id"
    assert_success
    assert_output -p "$expected"
}

@test "PR Already in Queue" {
    pr_queue="$(jq -n \
        --arg pull_request_id "$pull_request_id" \
        --arg base_ref "$base_ref" \
        --arg head_ref "$head_ref" '
        {
            "Queue": [
                {
                    "ID": "2",
                    "BaseRef": $base_ref,
                    "HeadRef": $head_ref
                }
            ],
            "InProgress": {
                "ID": "1",
                "BaseRef": "master",
                "HeadRef": "feature-1"
            },
            "Finished": []
        }
    ')"

    run pr_in_queue "$pr_queue" "$pull_request_id"
    assert_success
}

@test "PR not in Queue" {
    pr_queue="$(jq -n \
        --arg pull_request_id "$pull_request_id" \
        --arg base_ref "$base_ref" \
        --arg head_ref "$head_ref" '
        {
            "Queue": [
                {
                    "ID": "5",
                    "BaseRef": $base_ref,
                    "HeadRef": $head_ref
                }
            ],
            "InProgress": {
                "ID": "1",
                "BaseRef": "master",
                "HeadRef": "feature-1"
            },
            "Finished": []
        }
    ')"

    run pr_in_queue "$pr_queue" "$pull_request_id"
    assert_failure
}

@test "Add PR to Queue" {
    
    pr_queue="$(jq -n '
        {
            "Queue": [],
            "InProgress": {
                "ID": "1",
                "BaseRef": "master",
                "HeadRef": "feature-1"
            },
            "Finished": []
        }
    ')"
    
    expected="$(jq -n \
        --arg pull_request_id "$pull_request_id" \
        --arg base_ref "$base_ref" \
        --arg head_ref "$head_ref" '
        {
            "Queue": [
                {
                    "ID": "2",
                    "BaseRef": $base_ref,
                    "HeadRef": $head_ref
                }
            ],
            "InProgress": {
                "ID": "1",
                "BaseRef": "master",
                "HeadRef": "feature-1"
            },
            "Finished": []
        }
    ')"

    run pr_to_queue "$pr_queue" "$pull_request_id" "$base_ref" "$head_ref"
    assert_output -p "$expected"
}