export MOCK_AWS_CMDS=true
export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../../../files/buildspec-scripts/queue.sh'
    load 'testing_utils.sh'

    run_only_test "2"
}

@test "script is runnable" {
    run queue.sh
}

@test "Add New Commit to Queue" {
    # setup_metadb

    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"

    run add_commit_to_queue
    assert_success
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