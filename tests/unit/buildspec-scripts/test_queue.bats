export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../helpers/queue_utils.sh'
    load 'testing_utils.sh'
}

@test "script is runnable" {
    run queue.sh
}

@test "Add New Commit to Queue" {
    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"

    get_table() {
        echo "$(jq -n '
            [
                {
                    "pr_id": 1,
                    "commit_id": "commit-id-1",
                    "base_ref": "master",
                    "head_ref": "feature-1"
                }
            ]
        ')"
    }
    
    expected="$(jq -n '
        [
            {
                "pr_id": 1,
                "commit_id": "commit-id-1",
                "base_ref": "master",
                "head_ref": "feature-1"
            },
            {
                "pr_id": 2,
                "commit_id": "commit-id-2",
                "base_ref": "master",
                "head_ref": "feature-2"
            }
        ]
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