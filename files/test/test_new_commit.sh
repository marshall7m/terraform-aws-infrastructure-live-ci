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
                "Stack": {
                    "dev": {
                        "depends_on": ["shared-services"],
                        "Stack": {
                            "dev/foo": {
                                "depends_on": ["dev/bar"]
                            },
                            "dev/bar": {
                                "depends_on": []
                            }
                        }
                    }
                }
            }
        }
    ')
}