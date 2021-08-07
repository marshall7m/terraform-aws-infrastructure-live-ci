# Terraform AWS Infrastructure Live CI

Idea #1
AGW github webhook
    - determines the dependency between cfg dirs given the changed paths
    - update codepipeline with dependencies and tf/approval flow
    - dependency order:
        - if dir is a dependency of changed dir:
            - recursively add dependencies to list of directories until depedendencies have no dependepency of its own
        - order changed files by stage order paths

run pipeline
    - run tg plan
    - approve/decline tf plan
    - approve tf plan
    - apply tf cfg
    - run process above with dependencies

rollback:
    - rollback dependencies
    - rollback current tf cfg
    - rollback all of above
    - rollback none
rollback method:
    - via artifact store get previous version and update pipeline

Idea #2
- Use CB webhook instead of custom API Gateway webhook
- Poll for pipeline exeuction via CW rule
- If pipeline is in succeed state, update pipeline stages cfg
- Use Idea #1 pipeline process
- Codepipeline Work around rollback process:
    - within CB phase
    - if terraform apply fails, checkout terraform code of the last commit of base ref
    - if terraform code doesn’t exist within last commit, run terraform destroy with head ref

Idea #3:
- Cb with GitHub webhook that puts the commit into
    - SQS FIFO queue (although has retention max of 14 days)
    - DynamoDB
        - Use pull request number as primary key to only keep unique prs in table
            
- poll for step function execution with CW rule, use Lambda function as target
- if step function is in succeed state, update step function definition with next SQS queue commit within Lambda Function
- rollback task for each modified terraform cfg
- create choice task that allows the approver to decide what type of rollback within manual approval process:
    types of rollbacks:
        - rollback all within head commit
        - rollback selective cfg within head commit
            - if selective, run state machine task for committing currently terraform applied cfg?
    retry:
        - after rollback, route back to tf plan build
        - checkout recent pr commits and run plan
        - repeat manual approval/apply for x amount of retries
- task:
    - remove PR from dynamodb queue table if:
        - tf apply fails x amount of times
        - step function succeeds
Queue Ordering:
    - By CB build number
    - Feature: Override queue and run specific PR

Step function mapping:
    main SF:
        input: "{dir/": ["dir2"]}
        map iterator with no max concurrency
        passes each modified dir's dependency list into separate step function
    sub SF:
        input: ["dir2"]
        map iterator with 1 max concurrency
        run tf plan, approval, apply
PROS of child SF:
    - Lambda doesn't have to template new SF definition
    - Cleaner main SF diagram
CONS:
    - Doesn't give a good high-level overview of entire process
    - May be confusing to follow through
    


- Create rollbacks
	- git checkout master branch and run apply with master
		- cons:
			- If PR creates new tf directory, then the master branch can’t destroy a non-existing directory
	- Create initial new branch for testing the PR that is based on master
		- Merge PR into testing branch
		For full rollback before PR:
			- Checkout previous commit before PR merge to rollback cfg
			- Run apply-all to 
		Single Rollback:
			New cfg:
				- Remove all resources from cfg
				- Only keep the providers (doesn't work if provider is configured via attributes from other cfg within head ref)
				- Run terra apply
				- `rm rf dir/`
			Existing cfg:	
				- Revert back to previous commit and run apply
				- Push previous commit to PR
				Cons:
					- If previous commits has dependencies that have been changed by PR, then that may break previous commit changes
			cons:
				- If downstream dependencies, then those will error in terra plan if new dir


- Rollback for new providers:
    Scenario:
        - Terraform apply task is executed and updates the tf state with the new provider and resources
        - Terrraform plan will error if tf cfg is reverted back to base ref since it doesn't have the new provider defined
        - The provider is needed to destroy the new resources given Terraform needs to know what provider to destroy the resources from
    - Possible Solution:
        - Create script to indentify the provider address and the associated resources
        - Create downstream terraform deploy step function mapping to target destroy the new provider resources
        - Once the destroy deployment is approved/deployed, then revert the tf cfg to base ref and rerun the deploy process
        - Run the rollback process in the same order as the tg graph dependeny order
    
    tf flow map handled by rollback and not individual tf flow task
    indentifies new providers
    tf flow with new providers
    tf flow with reversion
Test tf plan within code build trigger sf function:
	- If exit code == 1; then remove PR from queue and retry build
    
## AWS SQS vs. DynamoDB vs. SimpleDB for PR Queue

### AWS SQS
Pros:
    - Offers FIFO (First-In First-Out) storage of queues. Maintains order integrity of the message coming in and out. 
    - Integrates with Step Function
    
Cons:
    - 14-day message retention period. Conflict with use case where PRs may be open for longer than 14 days. 

### AWS DynamoDb
Pros:
    - Persistent storage
    - Integrates with Step Funciton
    - Use partition and sort key to preserve order of PRs and optimize read requests
Cons:
    - Needs explicit partition key in order to query the table. Work around of using the scan command is not ideal since it scans every element and doesn't allow for ordering the results

### AWS SimpleDb
Pros:
    - Persistent storage
    - Simple to use API
    - Likely be fall under the free-tier given the small amount of storage and request needed for this use case
Cons:
    - Not integrated with Step Function (Easily worked around by using boto3 via Lambda function)


## AWS CodeBuild vs AWS Lambda for Trigger Step Function Operation

### AWS CodeBuild
Pros:
    - GitHub source integrated into build environment
    - Install required binaries `git`, `terraform`, and `terragrunt` via AWS ECR image
Cons:
    - Scripts must be imported via secondary source or be included with Github source

### AWS Lambda
Pros:
    - Run python commands right from `lambda_handler()` function
Cons:
    - Can't cleanly import required binaries
    - Git clone Github repository within Lambda handler

Tradeoffs between CP and SF:

CP:
Pros:
Integration source action
Cons:
No first class support for rollbacks and action failures
Doesn’t allow for visual representation of rollback process

## Problem

`terragrunt run-all xxx` commands have a limitation of inaccurately outputting the dependency values for child terraform configurations if the parent terraform configuration changes. The current advice is to exclude `terragrunt run-all xxx` from CI systems and run individual `terragrunt xxx` within each target directory. This imposes the tedious process of manually updating what directories to run on and the explicit ordering between them within the CI pipeline. 

## Update Process 

CodePipeline:
"""
When you update a pipeline, CodePipeline gracefully completes all the running actions and then fails the stages and pipeline executions where the running actions were completed. When a pipeline is updated, you will need to re-run your pipeline.
"""
https://docs.aws.amazon.com/codepipeline/latest/userguide/pipelines-edit.html

Step Function:
"""
When you update a state machine, your updates are eventually consistent. After a few seconds or minutes, all newly started executions will reflect your state machine's updated definition and roleARN. All currently running executions will run to completion under the previous definition and roleARN before updating.
"""
https://docs.aws.amazon.com/step-functions/latest/dg/getting-started.html#update-state-machine-step-3

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 0.14.0 |
| aws | >= 3.44 |

## Providers

| Name | Version |
|------|---------|
| archive | n/a |
| aws | >= 3.44 |
| github | n/a |
| random | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_id | AWS account id | `number` | n/a | yes |
| account\_parent\_cfg | Any modified child filepath of the parent path will be processed within the parent path associated Map task | <pre>list(object({<br>    name                     = string<br>    paths                    = list(string)<br>    voters                   = list(string)<br>    approval_count_required  = number<br>    rejection_count_required = number<br>  }))</pre> | n/a | yes |
| api\_name | Name of AWS Rest API | `string` | `"infrastructure-live"` | no |
| apply\_cmd | Terragrunt/Terraform apply command to run on target paths | `string` | `"terragrunt run-all apply -auto-approve"` | no |
| apply\_role\_assumable\_role\_arns | List of IAM role ARNs the apply CodeBuild action can assume | `list(string)` | `[]` | no |
| apply\_role\_name | Name of the IAM role used for running terr\* apply commands | `string` | `"infrastructure-live-apply"` | no |
| apply\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the apply Codebuild action | `list(string)` | `[]` | no |
| approval\_request\_sender\_email | Email address to use for sending approval requests | `string` | n/a | yes |
| artifact\_bucket\_force\_destroy | Determines if all bucket content will be deleted if the bucket is deleted (error-free bucket deletion) | `bool` | `false` | no |
| artifact\_bucket\_name | Name of the AWS S3 bucket to store AWS Step Function execution artifacts under | `string` | `null` | no |
| artifact\_bucket\_tags | Tags for AWS S3 bucket used to store step function artifacts | `map(string)` | `{}` | no |
| base\_branch | Base branch for repository that all PRs will compare to | `string` | `"master"` | no |
| build\_env\_vars | Base environment variables that will be provided for tf plan/apply builds | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| build\_name | CodeBuild project name | `string` | `"infrastructure-live-ci-build"` | no |
| build\_tags | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| cloudwatch\_event\_name | Name of the CloudWatch event that will monitor the Step Function | `string` | `"infrastructure-live-execution-event"` | no |
| cmk\_arn | AWS KMS CMK (Customer Master Key) ARN used to encrypt Step Function artifacts | `string` | `null` | no |
| common\_tags | Tags to add to all resources | `map(string)` | `{}` | no |
| create\_github\_token\_ssm\_param | Determines if an AWS System Manager Parameter Store value should be created for the Github token | `bool` | `true` | no |
| file\_path\_pattern | Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension. | `string` | `".+\\.(hcl|tf)$"` | no |
| get\_rollback\_providers\_build\_name | CodeBuild project name for getting new provider resources to destroy on deployment rollback | `string` | `"infrastructure-live-ci-get-rollback-providers"` | no |
| github\_token\_ssm\_description | Github token SSM parameter description | `string` | `"Github token used to give read access to the payload validator function to get file that differ between commits"` | no |
| github\_token\_ssm\_key | AWS SSM Parameter Store key for sensitive Github personal token | `string` | `"github-webhook-validator-token"` | no |
| github\_token\_ssm\_tags | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| github\_token\_ssm\_value | Registered Github webhook token associated with the Github provider. If not provided, module looks for pre-existing SSM parameter via `github_token_ssm_key` | `string` | `""` | no |
| plan\_cmd | Terragrunt/Terraform plan command to run on target paths | `string` | `"terragrunt run-all plan"` | no |
| plan\_role\_assumable\_role\_arns | List of IAM role ARNs the plan CodeBuild action can assume | `list(string)` | `[]` | no |
| plan\_role\_name | Name of the IAM role used for running terr\* plan commands | `string` | `"infrastructure-live-plan"` | no |
| plan\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the plan Codebuild action | `list(string)` | `[]` | no |
| queue\_pr\_build\_name | AWS CodeBuild project name for the build that queues PRs for the Step Function deployment | `string` | `"infrastructure-live-ci-queue-pr"` | no |
| repo\_name | Name of the GitHub repository | `string` | n/a | yes |
| step\_function\_name | Name of AWS Step Function machine | `string` | `"infrastructure-live-ci"` | no |
| terra\_img | Docker, ECR or AWS CodeBuild managed image to use for Terraform build projects | `string` | `null` | no |
| terragrunt\_parent\_dir | Parent directory within `var.repo_name` the `module.codebuild_trigger_sf` will run `terragrunt run-all plan` on<br>to retrieve terragrunt child directories that contain differences within their respective plan. Defaults<br>to the root of `var.repo_name` | `string` | `"./"` | no |
| trigger\_step\_function\_build\_name | Name of AWS CodeBuild project that will trigger the AWS Step Function | `string` | `"infrastructure-live-ci-trigger-sf"` | no |

## Outputs

No output.

<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

# TODO:
- Create approval flow:
    - Methods:
        - Slack
        - email

- Add retries to deploy and rollback apply states
    - Have get rollback providers state within each map iteration
    - Have rollback commit from base ref as source_version for rollback builds
    - Have a retry on map iteration or downstream tasks with base ref to revert changes
    - Catch apply error and run previous parallel iteration
    - Have a test rollback flow?
        - deploy changes
        - deploy rollback changes
        - if rollback changes succeed consider it ready to be applied

- transform testing-img to packer template?

Artifact Bucket:
    Initial (TF Apply this module):
        approval_mapping.json
            #TODO: Add example approval_mapping.json
    
    Codebuild Trigger Step Function:
        New PR Execution:
            approval_mapping.json
                execution_id.json
                    {
                        "Stack": {
                            "dev/foo": ["dev/bar", "dev/baz"]
                        },
                        "StackQueue": {
                            "dev/foo": ["dev/bar"]
                        }
                    }

    Deployment in Progress:
        approval_mapping.json
            execution_id.json
                {
                    "DeploymentQueue": [
                            ["dev/foo"], 
                            ["dev/bar", "dev/baz]
                        ],
                    "PlanUptoDate": true | false
                    "Accounts": {
                        {
                            "dev": {
                                "Deployments": {
                                    "dev/foo": {
                                        "Approval": {
                                            "Required": 2,
                                            "Count": 1,
                                            "Voters": [
                                                "approver@example.com"
                                            ]
                                        },
                                        "Rejection": {
                                            "Required": 2,
                                            "Count": 0,
                                            "Voters": []
                                        },
                                        "AwaitingApprovals": [
                                            "approver2@example.com"
                                        ]
                                        "TaskToken": "123"
                                    }
                                }
                            }
                        }
                    }
                }

## Why not use Terraform Workspace for deployment flow?

- Free tier only allows up to 5 users
    - Limited to the number of users who can approve the deployment unless users are willing to share Terraform Cloud accounts
- Single workspace doesn't allow for granular approval request and approval count based on configuration directory (e.g. `dev/` requires Bob's approval while `prod/` requires Bob and Ann's approval) Unless use separate workspaces for separate approvers?
- Requires scripting to meticulously trigger terraform workspace runs based on Terragrunt configuration dependencies?
    - TODO: (Research) - Does Terraform Workspace refresh previously queued plans once they are next in deployment?
    - TODO: (Research) - Does Terraform Workspace run update remote configuartion if PR commit changes configuration?

## Terraform Workspace Idea

- Use Codebuild script to generate dependency order
- Pass configuration to Terraform Workspace to create run via TF Cloud API
- Create Workspace webhook with AGW API to tell Codebuild to pass next configuration when apply is successful
- Create workspace for each AWS account
- Create workspace notifaction for email/slack

# Pipeline Flow 

Codebuild: Queue incoming PRs

Codebuild: Get depedency order and run Step Function
    Triggers:
        - Cloudwatch trigger by parent SF success
        - Webhook associated with current PR no matter state of execution
    - If new commit only contains changes to cfg within dependency run order:
        - run tg plan-all from changed cfg
        - reason: removes unnecessary tf plans that can be assumed to be not related to PR

SF:
    Lambda: 
        - Create/Update s3 artifact run order
        - Pass next cfg from depdency order to deployment
    -> Codebuild deployment
        Reject ->
        - Rollback upstream cfg
        - Allow for new commits for retries
            - Fail Step function execution to prevent CW trigger next in queue
            - Allow x retries of new commits to execution

If expire, then return expire action then rerun Lambda
queue

If new commit:
    - mark approval expired for ses response 
    - Fail execution once:
        - Apply Deployments are done


get parent directories with deps not in keys

pass dir to deployment flow

if deployment succeeds, pass dir to function

pop dir from any parent dependency list with dir

repeat process


Rollback?

Rollback parent dir

rollback parent dir's dependencies

once rollback succeeds, repeat process until parent dir's dependency doesn't exists in keys


deployment flow must output the path and pass path to lambda

CW event for SF success:
GH webhook for new commits -> Codebuild generate order

CW & GH webhook execution name via head_ref commit_id given source version is with PR

if nothing left in queue, checkout next PR ID
webhook deactivated if new PR (artifact queue is empty)

Artifact bucket:
- pr_queue.json:
    # PR Ids
    {
        Queue: [
            {
                "ID": 1
                "BaseRef": master
                "HeadRef": "feature"
                "Accounts": {
                    "dev": {
                        depends_on: []
                        "Stack": {
                            "foo": {
                                depends_on: ["bar"]
                            }
                            "baz": {
                                depends_on: []
                            }
                        }
                    }
                }
            },
            {
                "ID": 2
                "BaseRef": master
                "HeadRef": "feature-2"
            }
        ]
        InProgress: "1"
    }

[
    {
        "dev": {
            "foo": ["bar"]
        }
    }
]


Default Rollback:
rollback all deps failures and rollback single for PR target
    - Given deps failure will likely be unrelated to PR and will result in separate PR to fix it
    - If the PR modifies a leaf Terragrunt directory, rollback will only be for the leaf Terragrunt directory

Where to define rollback:
    - In Approval response
    - PR committer?

- run-{pr}-{short-commit-id}-{hash}/
    - approval.json
    - terraform.tfstate
    - Error/logs


SF input:
    {
        Path: "dev/bar",
        BaseSourceVersion: "master",
        HeadSourceVersion: "feature"
    }

FEATURES:
- Create webpage for displaying pr_queue.json

Scope of Codebuild trigger_sf build:

Create/update commit artifact that the webpage will retrieve data from
    - Update the next deploy stack data
    - Update the list of complete deployments
Pass next deploy stack to SF


TODO:
- Change Stack to use object:
    {
        "Account: { 
            "Dependencies": [] 
            "Stack": {
                "Parent": {
                    "Dependencies": [] 
                }
            }
        }
    }
    OR:

    {
        "Account": []
    }

    {
        "Account": {
            "Path": []
        }
    }