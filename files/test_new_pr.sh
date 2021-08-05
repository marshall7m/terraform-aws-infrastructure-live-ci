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

get_approval_mapping() {
    echo $(jq -n '
        {
            "Testing-Env": {
                "Name": "Testing-Env",
                "Paths": ["dev", "staging"],
                "Voters": ["test-user"],
                "ApprovalCountRequired": 2,
                "RejectionCountRequired": 2
            },
            "Global-Env": {
                "Name": "Global-Env",
                "Paths": ["shared-services", "security"],
                "Voters": ["test-user"],
                "ApprovalCountRequired": 2,
                "RejectionCountRequired": 2
            }
        }
    ')
}

get_tg_plan_out() {
    # terragrunt version: 0.31.0
    cat << EOT
INFO[0000] Stack at /Users/ci-user:
  => Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz])
  => Module /Users/ci-user/security/baz (excluded: false, dependencies: [])
  => Module /Users/ci-user/shared-services/doo (excluded: false, dependencies: [])
  => Module /Users/ci-user/dev/foo (excluded: false, dependencies: [/Users/ci-user/shared-services/bar]) 
WARN[0001] No double-slash (//) found in source URL /Users/ci-user/security/baz. Relative paths in downloaded Terraform code may not work.  prefix=[/Users/ci-user/security/baz] 
random_id.test: Refreshing state... [id=Jlxvnihksts]
random_id.test: Refreshing state... [id=8qWJRup1Fis]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:

Terraform will perform the following actions:

Plan: 0 to add, 0 to change, 0 to destroy.

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:

Terraform will perform the following actions:

Plan: 0 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  ~ random_value = "Jlxvnihksts" -> "security/baz"

─────────────────────────────────────────────────────────────────────────────

Changes to Outputs:
  ~ random_value = "8qWJRup1Fis" -> "do"

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
ERRO[0004] Module /Users/ci-user/shared-services/doo has finished with an error: 1 error occurred:
	* exit status 2
  prefix=[/Users/ci-user/shared-services/doo] 
ERRO[0004] Module /Users/ci-user/security/baz has finished with an error: 1 error occurred:
	* exit status 2
  prefix=[/Users/ci-user/security/baz] 
ERRO[0004] Dependency /Users/ci-user/security/baz of module /Users/ci-user/shared-services/bar just finished with an error. Module /Users/ci-user/shared-services/bar will have to return an error too.  prefix=[/Users/ci-user/shared-services/bar] 
ERRO[0004] Module /Users/ci-user/shared-services/bar has finished with an error: Cannot process module Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz]) because one of its dependencies, Module /Users/ci-user/security/baz (excluded: false, dependencies: []), finished with an error: 1 error occurred:
	* exit status 2
  prefix=[/Users/ci-user/shared-services/bar] 
ERRO[0004] Dependency /Users/ci-user/shared-services/bar of module /Users/ci-user/dev/foo just finished with an error. Module /Users/ci-user/dev/foo will have to return an error too.  prefix=[/Users/ci-user/dev/foo] 
ERRO[0004] Module /Users/ci-user/dev/foo has finished with an error: Cannot process module Module /Users/ci-user/dev/foo (excluded: false, dependencies: [/Users/ci-user/shared-services/bar]) because one of its dependencies, Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz]), finished with an error: Cannot process module Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz]) because one of its dependencies, Module /Users/ci-user/security/baz (excluded: false, dependencies: []), finished with an error: 1 error occurred:
	* exit status 2
  prefix=[/Users/ci-user/dev/foo] 
INFO[0004] time=2021-08-04T17:02:38-07:00 level=info msg=Executing hook: before_hook prefix=[/Users/ci-user/shared-services/doo]  
ERRO[0004] 4 errors occurred:
	* Cannot process module Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz]) because one of its dependencies, Module /Users/ci-user/security/baz (excluded: false, dependencies: []), finished with an error: 1 error occurred:
	* exit status 2


	* exit status 2
	* exit status 2
	* Cannot process module Module /Users/ci-user/dev/foo (excluded: false, dependencies: [/Users/ci-user/shared-services/bar]) because one of its dependencies, Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz]), finished with an error: Cannot process module Module /Users/ci-user/shared-services/bar (excluded: false, dependencies: [/Users/ci-user/security/baz]) because one of its dependencies, Module /Users/ci-user/security/baz (excluded: false, dependencies: []), finished with an error: 1 error occurred:
	* exit status 2s
EOT
}

trigger_sf


# generate local verison of testing repo