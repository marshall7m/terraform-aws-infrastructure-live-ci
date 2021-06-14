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
- Cb with GitHub webhook that puts the commit into SQS queue
- poll for step function execution with CW rule, use Lambda function as target
- if step function is in succeed state, update step function definition with next SQS queue commit within Lambda Function
- rollback task for each modified terraform cfg
- create choice task that allows the approver to decide what type of rollback within manual approval process:
    types of rollbacks:
        - rollback all within head commit
        - rollback selective cfg within head commit
            - if selective, run state machine task for committing currently terraform applied cfg?

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

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_id | AWS account id | `number` | n/a | yes |
| api\_name | Name of AWS Rest API | `string` | `"terraform-infrastructure-live"` | no |
| apply\_cmd | Terragrunt/Terraform apply command to run on target paths | `string` | `"terragrunt run-all apply -auto-approve"` | no |
| apply\_role\_assumable\_role\_arns | List of IAM role ARNs the apply CodeBuild action can assume | `list(string)` | `[]` | no |
| apply\_role\_name | Name of the IAM role used for running terr\* apply commands | `string` | `null` | no |
| apply\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the apply Codebuild action | `list(string)` | `[]` | no |
| artifact\_bucket\_force\_destroy | Determines if all bucket content will be deleted if the bucket is deleted (error-free bucket deletion) | `bool` | `false` | no |
| artifact\_bucket\_name | Name of the artifact S3 bucket to be created or the name of a pre-existing bucket name to be used for storing the pipeline's artifacts | `string` | `null` | no |
| artifact\_bucket\_tags | Tags to attach to provisioned S3 bucket | `map(string)` | `{}` | no |
| branch | Repo branch the pipeline is associated with | `string` | `"master"` | no |
| build\_env\_vars | Base environment variables that will be provided for each CodePipeline action build | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| build\_name | CodeBuild project name | `string` | `"infrastructure-live-ci"` | no |
| build\_tags | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| buildspec | CodeBuild buildspec path relative to the source repo root directory | `string` | `null` | no |
| cloudwatch\_event\_name | Name of the CloudWatch event that will monitor the CodePipeline | `string` | `"infrastructure-live-cp-execution-event"` | no |
| cmk\_arn | ARN of a pre-existing CMK to use for encrypting CodePipeline artifacts at rest | `string` | `null` | no |
| codestar\_name | AWS CodeStar connection name used to define the source stage of the pipeline | `string` | `null` | no |
| common\_tags | Tags to add to all resources | `map(string)` | `{}` | no |
| create\_github\_token\_ssm\_param | Determines if an AWS System Manager Parameter Store value should be created for the Github token | `bool` | `true` | no |
| github\_secret\_ssm\_description | Github secret SSM parameter description | `string` | `"Secret value for Github Webhooks"` | no |
| github\_secret\_ssm\_key | Key for github secret within AWS SSM Parameter Store | `string` | `"github-webhook-github-secret"` | no |
| github\_secret\_ssm\_tags | Tags for Github webhook secret SSM parameter | `map(string)` | `{}` | no |
| github\_token\_ssm\_description | Github token SSM parameter description | `string` | `"Github token used to give read access to the payload validator function to get file that differ between commits"` | no |
| github\_token\_ssm\_key | AWS SSM Parameter Store key for sensitive Github personal token | `string` | `"github-webhook-validator-token"` | no |
| github\_token\_ssm\_tags | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| github\_token\_ssm\_value | Registered Github webhook token associated with the Github provider. If not provided, module looks for pre-existing SSM parameter via `github_token_ssm_key` | `string` | `""` | no |
| pipeline\_name | Pipeline name | `string` | `"infrastructure-live-ci-pipeline"` | no |
| pipeline\_tags | Tags to attach to the pipeline | `map(string)` | `{}` | no |
| plan\_cmd | Terragrunt/Terraform plan command to run on target paths | `string` | `"terragrunt run-all plan"` | no |
| plan\_role\_assumable\_role\_arns | List of IAM role ARNs the plan CodeBuild action can assume | `list(string)` | `[]` | no |
| plan\_role\_name | Name of the IAM role used for running terr\* plan commands | `string` | `null` | no |
| plan\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the plan Codebuild action | `list(string)` | `[]` | no |
| repo\_filter\_groups | List of filter groups for the Github repository. The GitHub webhook request has to pass atleast one filter group in order to proceed to downstream actions | <pre>list(object({<br>    events                 = list(string)<br>    pr_actions             = optional(list(string))<br>    base_refs              = optional(list(string))<br>    head_refs              = optional(list(string))<br>    actor_account_ids      = optional(list(string))<br>    commit_messages        = optional(list(string))<br>    file_paths             = optional(list(string))<br>    exclude_matched_filter = optional(bool)<br>  }))</pre> | n/a | yes |
| repo\_name | Name of the GitHub repository | `string` | n/a | yes |
| role\_arn | Pre-existing IAM role ARN to use for the CodePipeline | `string` | `null` | no |
| role\_description | n/a | `string` | `"Allows Amazon Codepipeline to call AWS services on your behalf"` | no |
| role\_force\_detach\_policies | Determines attached policies to the CodePipeline service roles should be forcefully detached if the role is destroyed | `bool` | `false` | no |
| role\_max\_session\_duration | Max session duration (seconds) the role can be assumed for | `number` | `3600` | no |
| role\_path | Path to create policy | `string` | `"/"` | no |
| role\_permissions\_boundary | Permission boundary policy ARN used for CodePipeline service role | `string` | `""` | no |
| role\_tags | Tags to add to CodePipeline service role | `map(string)` | `{}` | no |
| stage\_parent\_paths | Parent directory path for each CodePipeline stage. Any modified child filepath of the parent path will be processed within the parent path associated stage | `list(string)` | n/a | yes |
| step\_function\_name | Name of AWS Step Function machine | `string` | `"infrastructure-live-step-function"` | no |
| trigger\_sf\_lambda\_function\_name | Name of the AWS Lambda function that will trigger a Step Function execution | `string` | `"infrastructure-live-step-function-trigger"` | no |
| update\_cp\_lambda\_function\_name | Name of the AWS Lambda function that will dynamically update AWS CodePipeline stages based on commit changes to the repository | `string` | `"infrastructure-live-update-cp-stages"` | no |

## Outputs

| Name | Description |
|------|-------------|
| codebuild\_arn | n/a |
| codebuild\_role\_arn | n/a |
| codepipeline\_arn | n/a |
| codepipeline\_role\_arn | n/a |
| codestar\_arn | n/a |

<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->