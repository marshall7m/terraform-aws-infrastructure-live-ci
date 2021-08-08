export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
script_logging_level="DEBUG"
source ./utils.sh
source ./testing_utils.sh


get_pr_queue() {
    echo $(jq -n '
        {
            "Queue": [
                {
                    "ID": 2,
                    "BaseRef": "master",
                    "HeadRef": "feature-2"
                }
            ],
            "InProgress": {
                "ID": 1,
                "BaseRef": "master",
                "HeadRef": "feature",
                "Stack": {}
            }
        }
    ')
}

# get_approval_mapping() {
#     echo $(jq -n '
#         {
#             "Testing-Env": {
#                 "Name": "Testing-Env",
#                 "Paths": ["dev-account"],
#                 "Voters": ["test-user"],
#                 "ApprovalCountRequired": 2,
#                 "RejectionCountRequired": 2
#             },
#             "Global-Env": {
#                 "Name": "Global-Env",
#                 "Paths": ["shared-services", "security"],
#                 "Voters": ["test-user"],
#                 "ApprovalCountRequired": 2,
#                 "RejectionCountRequired": 2
#             }
#         }
#     ')
# }

get_approval_mapping() {
    echo $(jq -n '
        {
            "Testing-Env": {
                "Name": "Testing-Env",
                "Paths": ["directory_dependency/dev-account"],
                "Voters": ["test-user"],
                "ApprovalCountRequired": 2,
                "RejectionCountRequired": 2
            }
        }
    ')
}

log "Setting up testing repo" "INFO"
export SKIP_TERRAFORM_TESTING_STATE=true

# setup_test_env \
#   --clone-url "https://github.com/marshall7m/infrastructure-live-testing-template.git" \
#   --clone-destination "./tmp" \
#   --terragrunt-working-dir "directory_dependency" \
#   --modify "directory_dependency/dev-account/us-west-2/env-one/doo" \
#   --modify "directory_dependency/dev-account/us-west-2/env-one/foo"

log "Testing repo is ready" "INFO"

CODEBUILD_INITIATOR="rule/foo"
EVENTBRIDGE_RULE="rule/foo"
trigger_sf


#TODO set up testing env for step function event