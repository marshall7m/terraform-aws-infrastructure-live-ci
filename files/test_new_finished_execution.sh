export MOCK_TG_CMDS=true
export MOCK_GIT_CMDS=true
export MOCK_AWS_CMDS=true
script_logging_level="DEBUG"
source ./utils.sh
source ./testing_utils.sh



export CODEBUILD_INITIATOR="rule/foo"
export EVENTBRIDGE_RULE="rule/foo"
export EVENTBRIDGE_EVENT=$(jq -n \
    '{
        "Path": "d", 
        "Status": "SUCCESS",
        "BaseSourceVersion": "refs/pull/1/head^{2f4aa7782602b2b433f3ff6acb2984695d13e3fd}",
        "HeadSourceVersion": "refs/pull/1/head^{2f4aa7782602b2b433f3ff6acb2984695d13e3fd}",
        "CommitOrderID": 1
    } 
    | tojson'
)

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
                "HeadRef": "feature-1",
                "CommitStack": {
                    "1": {
                        "BaseSourceVersion": "base",
                        "HeadSourceVersion": "head",
                        "DeployStack": {
                            "Dev": { 
                                "Dependencies": [],
                                "Stack": {
                                    "foo/": {
                                        "Dependencies": [] 
                                    }
                                }
                            },
                            "Prod": { 
                                "Dependencies": [],
                                "Stack": {
                                    "doo/": {
                                        "Dependencies": [] 
                                    }
                                }
                            },
                        },
                        "RollbackPaths": []
                    }
                }   
            }
        }
    ')
}


trigger_sf