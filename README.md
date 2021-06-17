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
    - Manually run lambda to ignore queue and run specific pr ID

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
    
## AWS SQS vs. DynamoDB vs. SimpleDB

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
| null | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_id | AWS account id | `number` | n/a | yes |
| api\_name | Name of AWS Rest API | `string` | `"infrastructure-live"` | no |
| apply\_cmd | Terragrunt/Terraform apply command to run on target paths | `string` | `"terragrunt run-all apply -auto-approve"` | no |
| apply\_role\_assumable\_role\_arns | List of IAM role ARNs the apply CodeBuild action can assume | `list(string)` | `[]` | no |
| apply\_role\_name | Name of the IAM role used for running terr\* apply commands | `string` | `"infrastructure-live-apply"` | no |
| apply\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the apply Codebuild action | `list(string)` | `[]` | no |
| artifact\_bucket\_force\_destroy | Determines if all bucket content will be deleted if the bucket is deleted (error-free bucket deletion) | `bool` | `false` | no |
| artifact\_bucket\_name | Name of the artifact S3 bucket to be created or the name of a pre-existing bucket name to be used for storing the pipeline's artifacts | `string` | `null` | no |
| artifact\_bucket\_tags | Tags to attach to provisioned S3 bucket | `map(string)` | `{}` | no |
| base\_branch | Base branch for repository that all PRs will compare to | `string` | `"master"` | no |
| build\_env\_vars | Base environment variables that will be provided for each CodePipeline action build | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| build\_name | CodeBuild project name | `string` | `"infrastructure-live-ci-build"` | no |
| build\_tags | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| buildspec | CodeBuild buildspec path relative to the source repo root directory | `string` | `null` | no |
| cloudwatch\_event\_name | Name of the CloudWatch event that will monitor the Step Function | `string` | `"infrastructure-live-execution-event"` | no |
| cmk\_arn | ARN of a pre-existing CMK to use for encrypting CodePipeline artifacts at rest | `string` | `null` | no |
| codestar\_name | AWS CodeStar connection name used to define the source stage of the pipeline | `string` | `null` | no |
| common\_tags | Tags to add to all resources | `map(string)` | `{}` | no |
| create\_github\_token\_ssm\_param | Determines if an AWS System Manager Parameter Store value should be created for the Github token | `bool` | `true` | no |
| dynamodb\_tags | Tags to add to DynamoDB | `map(string)` | `{}` | no |
| file\_path\_pattern | Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension. | `string` | `".+\\.(hcl|tf)$"` | no |
| github\_token\_ssm\_description | Github token SSM parameter description | `string` | `"Github token used to give read access to the payload validator function to get file that differ between commits"` | no |
| github\_token\_ssm\_key | AWS SSM Parameter Store key for sensitive Github personal token | `string` | `"github-webhook-validator-token"` | no |
| github\_token\_ssm\_tags | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| github\_token\_ssm\_value | Registered Github webhook token associated with the Github provider. If not provided, module looks for pre-existing SSM parameter via `github_token_ssm_key` | `string` | `""` | no |
| lambda\_trigger\_sf\_function\_name | Name of AWS Lambda function that will trigger the AWS Step Function | `string` | `"infrastructure-live-ci-trigger-sf"` | no |
| pipeline\_tags | Tags to attach to the pipeline | `map(string)` | `{}` | no |
| plan\_cmd | Terragrunt/Terraform plan command to run on target paths | `string` | `"terragrunt run-all plan"` | no |
| plan\_role\_assumable\_role\_arns | List of IAM role ARNs the plan CodeBuild action can assume | `list(string)` | `[]` | no |
| plan\_role\_name | Name of the IAM role used for running terr\* plan commands | `string` | `"infrastructure-live-plan"` | no |
| plan\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the plan Codebuild action | `list(string)` | `[]` | no |
| queue\_pr\_build\_name | AWS CodeBuild project name for the build that writes to the PR queue table hosted on AWS DynamodB | `string` | `"infrastructure-live-ci-queue-pr"` | no |
| repo\_name | Name of the GitHub repository | `string` | n/a | yes |
| role\_arn | Pre-existing IAM role ARN to use for the CodePipeline | `string` | `null` | no |
| role\_description | n/a | `string` | `"Allows Amazon Codepipeline to call AWS services on your behalf"` | no |
| role\_force\_detach\_policies | Determines attached policies to the CodePipeline service roles should be forcefully detached if the role is destroyed | `bool` | `false` | no |
| role\_max\_session\_duration | Max session duration (seconds) the role can be assumed for | `number` | `3600` | no |
| role\_path | Path to create policy | `string` | `"/"` | no |
| role\_permissions\_boundary | Permission boundary policy ARN used for CodePipeline service role | `string` | `""` | no |
| role\_tags | Tags to add to CodePipeline service role | `map(string)` | `{}` | no |
| simpledb\_name | Name of the AWS SimpleDB domain used for queuing repo PRs | `string` | `"infrastructure-live-ci-PR-queue"` | no |
| stage\_parent\_paths | Parent directory path for each CodePipeline stage. Any modified child filepath of the parent path will be processed within the parent path associated stage | `list(string)` | n/a | yes |
| step\_function\_name | Name of AWS Step Function machine | `string` | `"infrastructure-live-ci"` | no |

## Outputs

No output.

<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->