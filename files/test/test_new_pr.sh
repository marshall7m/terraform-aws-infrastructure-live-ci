export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
script_logging_level="DEBUG"
source ../utils.sh
source ../testing_utils.sh


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

