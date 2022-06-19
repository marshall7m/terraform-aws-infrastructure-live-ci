# Terraform AWS Infrastructure Live CI
 
## Problem
 
`terragrunt run-all` commands have a limitation of inaccurately outputting the dependency values for child terraform plans if the dependency configuration changes. The current advice is to exclude `terragrunt run-all` from CI systems and run individual `terragrunt` commands within each target directory (see [GitHub issue](https://github.com/gruntwork-io/terragrunt/issues/720#issuecomment-497888756)). This imposes the tedious process of manually determining what directories to run on and the explicit ordering between them within the CI pipeline. As other users of Terragrunt have [stated](https://github.com/gruntwork-io/terragrunt/issues/262
), there's a need for some way to manage the dependency changes before applying the changes that were made within the PR. This module brings an AWS native solution to this problem.
 
 
## Solution
 
Before getting into how the entire module works, we'll dive into the proposed solution to the problem and how it boils down to a specific piece of the CI pipeline. As mentioned above, the `terragrunt run-all` command will produce an inaccurate dependency value for child directories that depend on parent directories that haven't been applied yet. Obviously if all parent dependencies were applied beforehand, the dependency value within the child Terraform plan would then be valid. So what if we created a component of a CI pipeline that detects all dependency paths that include changes, run a separate approval flow for each of those paths, and then run an approval flow for the child path? This will ensure that every `terragrunt plan` command contains valid dependency values.
 
This module includes two different approaches to detecting changes which we will call "graph scan" and "plan scan". The scan type can be toggled via the `create_deploy_stack_graph_scan` Terraform variable. The graph scan will initially use the `git diff` command to collect directories that contain .tf or .hcl file changes. Using a mapping of the terragrunt directories and their associated dependency list, the script will recursively collect directories that contain dependency changes. The plan scan approach will run the command `terragrunt run-all plan -detailed-exitcode` (command is shortened to include only relevant arguments). The `terragrunt run-all plan` portion will traverse from the root terragrunt directory down to every child Terragrunt directory. It will then run `teraform plan -detailed-exitcode` within each directory and output the [exitcode](https://www.terraform.io/cli/commands/plan#detailed-exitcode) that represents whether the plan contains changes or not. If the directory does contain changes, the directory and it's associated dependencies that also have changes will be collected. This excludes dependencies that are unchanged but upstream from changed directories. For example, consider the following directory dependency tree:

```
dev/vpc
    \
    dev/rds
        \
        dev/ec2
```
if `dev/rds` and `dev/ec2` have changes, only `dev/rds` and `dev/ec2` will be collected.

After all directories and their associated dependencies are gathered, they are put into separate database records that will then be used by a downstream Lambda Function. The Lambda Function will determine the order in which the directories are passed into the Step Function deployment flow. This entire process includes no human intervention and removes the need for users to define the deployment ordering all together. The actual code that runs this process is defined [here](./buildspecs/create_deploy_stack/create_deploy_stack.py).
 
 
## Design
 
![Cloudcraft](cloudcraft.png)
 
1. A GitHub user commits to a feature branch and creates a PR to merge into the trunk branch. The trunk branch represents the live Terraform configurations and should be reflected within the Terraform state files. As the user continues to push Terraform related commit changes to the PR, a Lambda Function referenced as `merge_lock` within the module will update the commit status notifying if merging the PR is available or not. Merging will be locked if a merged PR is in the process of the CI pipeline. Once the CI pipeline is finished, the downstream Lambda Function (see #4) will update the merge lock status value.
 
   `**NOTE The PR committer will have to create another commit once the merge lock status is unlocked to get an updated merge lock commit status. **`
 
2. If the merge lock commit status is unlocked, a user with merge permissions can then merge the PR.
 
3. Once the PR is merged, a Codebuild project referenced as `pr_plan` within the module will update the merge lock status and then scan the trunk branch for changes made from the PR. The build will insert records into the metadb for each directory that contains differences in its respective Terraform plan. After the records are inserted, the build will invoke a different Lambda Function.
 
4. A Lambda Function referenced within the module as `trigger_sf` will select metadb records for Terragrunt directories with account and directory level dependencies met. The Lambda will convert the records into json objects and pass each json as input into separate Step Function executions. An in-depth description of the Step Function flow can be found under the `Step Execution Flow` section.
 
5. After every Step Function execution, a Cloudwatch event rule will invoke the `trigger_sf` Lambda Function mentioned in step #4. The Lambda Function will update the Step Function execution's associated metadb record status with the Step Function execution status. The Lambda Function will then repeat the same process as mentioned in step #4 until there are no records that are waiting to be runned with a Step Function execution. As stated above, the Lambda Function will update the merge lock status value to allow other Terraform related PRs to be merged.
 
## Step Function Execution Flow
 
### Input
 
Each execution is passed a json input that contains record attributes that will help configure the tasks within the Step Function. A sample json input will look like the following:
 
```
{
 "execution_id": "run-1-c8c5-dev-baz-729",
 "is_rollback": false,
 "pr_id": 1,
 "commit_id": "c8c5f6afc7345bd21cd79acaf740dc18b60755e3",
 "base_ref": "refs/heads/master",
 "head_ref": "refs/heads/feature-5320d796-6511-4b05-8adf-47382b46afe2",
 "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
 "cfg_deps": [
   "directory_dependency/dev-account/global"
 ],
 "status": "running",
 "plan_command": "terragrunt plan --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/baz",
 "deploy_command": "terragrunt apply --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/baz -auto-approve",
 "new_providers": ["registry.terraform.io/hashicorp/null"],
 "new_resources": ["null_resource.this"],
 "account_name": "dev",
 "account_path": "directory_dependency/dev-account",
 "account_deps": [
   "shared_services"
 ],
 "voters": [
   "success@simulator.amazonses.com"
 ],
 "approval_voters": [],
 "min_approval_count": 1,
 "rejection_voters": [],
 "min_rejection_count": 1,
 "plan_role_arn": "arn:aws:iam::111111111111:role/terraform-aws-infrastructure-live-ci-plan",
 "deploy_role_arn": "arn:aws:iam::111111111111:role/terraform-aws-infrastructure-live-ci-deploy"
}
```
 
`execution_id`: An unique identifier that represents the execution name. The ID is formatted to be `run-{pr_id}-{first four digits of commit_id}-{account_name}-{leaf directory of cfg_path}-{random three digits}`. Only three random digits are used because if the record has a long account_name and/or cfg_path, the execution_id may exceed Step Function's 80 character or less execution name limit.
 
`is_rollback`: Determines if the execution pertains to a deployment that will rollback changes from a previous execution. (See section `Rollbacks` for more info)
 
`pr_id`: Pull Request Number
 
`commit_id`: Pull Request merge commit ID
 
`base_ref`: Branch that the pull request was merged into
 
`head_ref`: Branch that was merged into the base branch
 
`cfg_path`: A directories relative path to the GitHub repository's root path
 
`cfg_deps`: List of `cfg_path` directories that this `cfg_path` depends on. Dependencies are defined via Terragrunt dependencies blocks (see this [Terragrunt page](https://terragrunt.gruntwork.io/docs/reference/config-blocks-and-attributes/#dependencies) for more info)
 
`status`: Status of the Step Function execution. Statuses can be `waiting|running|succeeded|failed|aborted`
 
`plan_command`: Terragrunt command used to display the Terraform plan within the Step Function `Plan` task
 
`deploy_command`: Terragrunt command used to deploy the Terraform configurations within the Step Function `Deploy` task
 
`new_providers`: List of new providers introduced by the pull request (See section `Rollbacks` for more info)
 
`new_resources`: List of new provider resources that were deployed (See section `Rollbacks` for more info)
 
`account_name`: AWS account the `cfg_path` will deploy resources to
 
`account_deps`: List of AWS accounts (`account_name`) the record's `account_name` depends on
 
`voters`: List of email addresses to send approval request to
 
`approval_voters`: List of `voters` who have approved the deployment
 
`min_approval_count`: Minimum number of approvals needed to deploy
 
`rejection_voters`: List of `voters` who have rejected the deployment
 
`min_rejection_count`: Minimum number of rejections needed to decline the deployment
 
`plan_role_arn`: AWS IAM role ARN used to run `plan_command`
 
`deploy_role_arn`: AWS IAM role ARN used to run `deploy_command`
 
 
### Definition
 
The Step Function definition comprises of six tasks.
 
`Plan`: A CodeBuild project referenced as `terra_run` within the module will run the record's associated `plan_command`. This will output the Terraform plan to the CloudWatch logs for users to see what resources will be created/modified/deleted.
 
`Request Approval`: A Lambda Function referenced as `approval_request` within the module will send an approval request via AWS SES to every email address defined under the record's `voters` attribute. When a voter approves/rejects a deployment, a different Lambda Function referenced as `approval_response` will update the records approval or rejection count. Once the minimum approval count is met, the Lambda Function will send a task success token back to the associated Step Function execution.
 
`Approval Results`: Based on which minimum approval count is met, this task will conditionally choose which downstream task to run next. If the approval count is met, the `Deploy` task will be runned. If the rejection count is met, the `Reject` task will be runned.
 
`Deploy`: The `terra_run` CodeBuild project will run the record's associated `deploy_command`. This Terraform apply output will be displayed within the CloudWatch logs for users to see what resources were created/modified/deleted. If the deployment created new provider resources, a bash script will update the record's associated `new_resources` attribute with the new provider resource addresses that were created. The "Rollback New Provider Resources" section below will explain how the `new_resources` attribute will be used. 
 
`Success`: If all Step Function tasks were successful, this task will output a status of `succeeded` along other output attributes.
 
`Reject`: If any Step Function task was unsuccessful, this task will output a status of `failed` along other output attributes.
 
### Rollback New Provider Resources
 
Lets say a PR introduces a new provider and resource block. The PR is merged and the deployment associated with the new provider resource succeeds. For some reason a downstream deployment fails and the entire PR needs to be reverted. The revert PR is created and is merged. The directory containing the new provider resource will be non-existent within the revert PR although the terraform state file associated with the directory will still contain the new provider resources.Given that the provider block and it's associated provider credentials are gone, Terraform will output an error when trying to initialize the directory within the deployment flow. This type of scenario is also referenced in this [StackOverflow post](https://stackoverflow.com/a/57829202/12659025).
 
To handle this scenario, the CI pipeline will document which directories define new provider resources within the metadb. After every deployment, any new provider resources that were deployed will also be documented. If any deployment flow fails, the CI pipeline will start Step Function executions for every directory that contains new providers and target destroy the new provider resources. To see it in action, run the [test_rollback_providers.py](./tests/integration/test_rollback_providers.py) test.
 
## Infrastructure Repository Requirements
 
- Terraform files can be present but they must be referenced by Terragrunt configurations in order for it be detected by the CI workflow
- Configuration can't depend on environment variables that are not already passed to the builds
 
## Why AWS Step Function for deployment flow?
 
It would seem like CodePipeline would be the go to AWS service for hosting the deployment workflow. After a long period of trying both I found the following trade offs.
 
### Step Function
 
#### Pros
 
- Ability to handle complex conditional workflows by using [choice states](https://docs.aws.amazon.com/step-functions/latest/dg/amazon-states-language-choice-state.html)
- Ability to capture errors and define fallback states (see [here](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-error-handling.html) for more info)
- Updates to the workflow in itself will not fail the current execution and changes will be reflected within future executions [(reference)](https://docs.aws.amazon.com/step-functions/latest/dg/getting-started.html#update-state-machine-step-3
)
- Ability to customize the execution name which is useful searching for executions within the console
 
### CodePipeline
 
#### Pros
 
- Integrated approval flow managed via IAM users/roles
- Simple and intuitive GUI
- Satisfied with just being able to do account-level execution concurrency
- A single AWS account with a simple plan, approval, deploy workflow is only needed
 
#### Cons
 
- Can't handle complex task branching. The current implementation is fairly simple but newer versions of this module may contain feature Step Function definitions that handle complex deployment workflows.
- Concurrent runs are not available which can lead slow deployment rollouts for changes within deeply rooted dependencies or changes within a large amount of independent sibling directories
- Updates to the pipeline in itself causes the execution to fail and prevent any downstream actions from running as described [here](https://docs.aws.amazon.com/codepipeline/latest/userguide/pipelines-edit.html
)
- Free tier only allows for one free pipeline a month. After the free tier, the cost for each active pipeline is $1 a month not including the additional charges for storing the CodePipeline artifacts within S3. Given that this module is intended for handling a large amount of AWS accounts, a CodePipeline for each account would be necessary which would spike up the total cost for running this module.
 
## Pricing
 
### Lambda
 
The AWS Lambda free tier includes one million free requests per month and 400,000 GB-seconds of compute time per month. Given the use of the Lambda Functions are revolved around infrastructure changes, the total amount of invocations will likely be minimal and will probably chip away only a tiny fraction of the free tier allocation.
 
### CodeBuild
 
The build.general1.small instance type is used for both builds within this module. Given that Terraform is revolved around API requests to the Terraform providers, a large CPU instance is not that much of a neccessity. The price per build will vary since the amount of resources within Terraform configurations will also vary. The more Terraform resources the configuration manages, the longer the build will be and hence the larger the cost will be.
 
### Step Function

The cost for the Step Function machine is based on state transitions. Luckily 4,000 state transitions per month are covered under the free tier. The Step Function definition contains only a minimal amount of state transitions. Unless the infrastructure repo contains frequent and deeply rooted dependency changes, the free tier limit will likely never be exceeded.
 
### RDS
 
The metadb uses a [Aurora Serverless](https://aws.amazon.com/rds/aurora/serverless/) PostgreSQL database type. Essentially a serverless database will allow users to only pay for when the database is in use and free up users from managing the database capacity given that it will automatically scale based on demand. The serverless type is beneficial for this use case given that the metadb is only used within CI services after a PR merge event. Since this module is dealing with live infrastructure and not application changes, there will likely be long periods of time between PR merges. The serverless database starts with one ACU (Aurora Capacity Units) which contains two GB of memory. The use of the database is likely never to scale beyond using two GB of memory so using one ACU will likely be constant.
 
### EventBridge
 
Given EventBridge rules and event deliveries are free, the Step Function execution rule and event delivery to the Lambda Function produces no cost.


## Cost

### Cost estimate in the us-west-2 region via [Infracost](https://github.com/infracost/infracost):

```
 Name                                                                                    Monthly Qty  Unit                        Monthly Cost 
                                                                                                                                               
 aws_api_gateway_rest_api.this                                                                                                                 
 └─ Requests (first 333M)                                                        Monthly cost depends on usage: $3.50 per 1M requests          
                                                                                                                                               
 aws_rds_cluster.metadb                                                                                                                        
 ├─ Aurora serverless                                                            Monthly cost depends on usage: $0.06 per ACU-hours            
 ├─ Storage                                                                      Monthly cost depends on usage: $0.10 per GB                   
 ├─ I/O requests                                                                 Monthly cost depends on usage: $0.20 per 1M requests          
 └─ Snapshot export                                                              Monthly cost depends on usage: $0.01 per GB                   
                                                                                                                                               
 aws_secretsmanager_secret.ci_metadb_user                                                                                                      
 ├─ Secret                                                                                         1  months                             $0.40 
 └─ API requests                                                                 Monthly cost depends on usage: $0.05 per 10k requests         
                                                                                                                                               
 aws_secretsmanager_secret.master_metadb_user                                                                                                  
 ├─ Secret                                                                                         1  months                             $0.40 
 └─ API requests                                                                 Monthly cost depends on usage: $0.05 per 10k requests         
                                                                                                                                               
 aws_sfn_state_machine.this                                                                                                                    
 └─ Transitions                                                                  Monthly cost depends on usage: $0.025 per 1K transitions      
                                                                                                                                               
 module.codebuild_create_deploy_stack.aws_cloudwatch_log_group.this[0]                                                                         
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.codebuild_create_deploy_stack.aws_codebuild_project.this                                                                               
 └─ Linux (general1.small)                                                       Monthly cost depends on usage: $0.005 per minutes             
                                                                                                                                               
 module.codebuild_pr_plan.aws_cloudwatch_log_group.this[0]                                                                                     
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.codebuild_pr_plan.aws_codebuild_project.this                                                                                           
 └─ Linux (general1.small)                                                       Monthly cost depends on usage: $0.005 per minutes             
                                                                                                                                               
 module.codebuild_terra_run.aws_cloudwatch_log_group.this[0]                                                                                   
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.codebuild_terra_run.aws_codebuild_project.this                                                                                         
 └─ Linux (general1.small)                                                       Monthly cost depends on usage: $0.005 per minutes             
                                                                                                                                               
 module.github_webhook_validator.aws_cloudwatch_log_group.agw[0]                                                                               
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.github_webhook_validator.module.lambda.aws_cloudwatch_log_group.this[0]                                                                
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.github_webhook_validator.module.lambda.aws_lambda_function.this[0]                                                                     
 ├─ Requests                                                                     Monthly cost depends on usage: $0.20 per 1M requests          
 └─ Duration                                                                     Monthly cost depends on usage: $0.0000166667 per GB-seconds   
                                                                                                                                               
 module.lambda_approval_request.aws_cloudwatch_log_group.this[0]                                                                               
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.lambda_approval_request.aws_lambda_function.this[0]                                                                                    
 ├─ Requests                                                                     Monthly cost depends on usage: $0.20 per 1M requests          
 └─ Duration                                                                     Monthly cost depends on usage: $0.0000166667 per GB-seconds   
                                                                                                                                               
 module.lambda_approval_response.aws_cloudwatch_log_group.this[0]                                                                              
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.lambda_approval_response.aws_lambda_function.this[0]                                                                                   
 ├─ Requests                                                                     Monthly cost depends on usage: $0.20 per 1M requests          
 └─ Duration                                                                     Monthly cost depends on usage: $0.0000166667 per GB-seconds   
                                                                                                                                               
 module.lambda_merge_lock.aws_cloudwatch_log_group.this[0]                                                                                     
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.lambda_merge_lock.aws_lambda_function.this[0]                                                                                          
 ├─ Requests                                                                     Monthly cost depends on usage: $0.20 per 1M requests          
 └─ Duration                                                                     Monthly cost depends on usage: $0.0000166667 per GB-seconds   
                                                                                                                                               
 module.lambda_trigger_sf.aws_cloudwatch_log_group.this[0]                                                                                     
 ├─ Data ingested                                                                Monthly cost depends on usage: $0.50 per GB                   
 ├─ Archival Storage                                                             Monthly cost depends on usage: $0.03 per GB                   
 └─ Insights queries data scanned                                                Monthly cost depends on usage: $0.005 per GB                  
                                                                                                                                               
 module.lambda_trigger_sf.aws_lambda_function.this[0]                                                                                          
 ├─ Requests                                                                     Monthly cost depends on usage: $0.20 per 1M requests          
 └─ Duration                                                                     Monthly cost depends on usage: $0.0000166667 per GB-seconds   
                                                                                                                                               
 OVERALL TOTAL                                                                                                                           $0.80 
──────────────────────────────────
95 cloud resources were detected:
∙ 22 were estimated, all of which include usage-based costs, see https://infracost.io/usage-file
∙ 66 were free:
  ∙ 12 x aws_iam_policy
  ∙ 11 x aws_iam_role_policy_attachment
  ∙ 7 x aws_iam_role
  ∙ 4 x aws_api_gateway_method_response
  ∙ 4 x aws_lambda_layer_version
  ∙ 4 x aws_ssm_parameter
  ∙ 3 x aws_lambda_permission
  ∙ 2 x aws_api_gateway_integration
  ∙ 2 x aws_api_gateway_method
  ∙ 2 x aws_api_gateway_method_settings
  ∙ 2 x aws_api_gateway_resource
  ∙ 2 x aws_cloudwatch_event_rule
  ∙ 2 x aws_cloudwatch_event_target
  ∙ 2 x aws_codebuild_webhook
  ∙ 2 x aws_secretsmanager_secret_version
  ∙ 1 x aws_api_gateway_account
  ∙ 1 x aws_api_gateway_deployment
  ∙ 1 x aws_api_gateway_model
  ∙ 1 x aws_api_gateway_stage
  ∙ 1 x aws_lambda_function_event_invoke_config
∙ 7 are not supported yet, see https://infracost.io/requested-resources:
  ∙ 4 x aws_api_gateway_integration_response
  ∙ 1 x aws_ses_email_identity
  ∙ 1 x aws_ses_identity_policy
  ∙ 1 x aws_ses_template
```

## CLI Requirements
 
Requirements below are needed in order to run `terraform apply` within this module. This module contains null resources that run bash scripts to install pip packages, zip directories, and query the RDS database.
 
| Name | Version |
|------|---------|
| awscli | >= 1.22.5 |
| python3 | >= 3.9 |
| pip | >= 22.0.4 |
 
<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 0.14.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.44 |
| <a name="requirement_github"></a> [github](#requirement\_github) | >= 4.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >=3.2.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | n/a |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.44 |
| <a name="provider_github"></a> [github](#provider\_github) | >= 4.0 |
| <a name="provider_null"></a> [null](#provider\_null) | n/a |
| <a name="provider_random"></a> [random](#provider\_random) | >=3.2.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_agw_role"></a> [agw\_role](#module\_agw\_role) | github.com/marshall7m/terraform-aws-iam//modules/iam-role | v0.1.0 |
| <a name="module_codebuild_create_deploy_stack"></a> [codebuild\_create\_deploy\_stack](#module\_codebuild\_create\_deploy\_stack) | github.com/marshall7m/terraform-aws-codebuild | v0.1.0 |
| <a name="module_codebuild_pr_plan"></a> [codebuild\_pr\_plan](#module\_codebuild\_pr\_plan) | github.com/marshall7m/terraform-aws-codebuild | v0.1.0 |
| <a name="module_codebuild_terra_run"></a> [codebuild\_terra\_run](#module\_codebuild\_terra\_run) | github.com/marshall7m/terraform-aws-codebuild | v0.1.0 |
| <a name="module_cw_event_rule_role"></a> [cw\_event\_rule\_role](#module\_cw\_event\_rule\_role) | github.com/marshall7m/terraform-aws-iam//modules/iam-role | v0.1.0 |
| <a name="module_cw_event_terra_run"></a> [cw\_event\_terra\_run](#module\_cw\_event\_terra\_run) | github.com/marshall7m/terraform-aws-iam//modules/iam-role | v0.1.0 |
| <a name="module_github_webhook_validator"></a> [github\_webhook\_validator](#module\_github\_webhook\_validator) | github.com/marshall7m/terraform-aws-github-webhook | v0.1.0 |
| <a name="module_lambda_approval_request"></a> [lambda\_approval\_request](#module\_lambda\_approval\_request) | github.com/marshall7m/terraform-aws-lambda | v0.1.0 |
| <a name="module_lambda_approval_response"></a> [lambda\_approval\_response](#module\_lambda\_approval\_response) | github.com/marshall7m/terraform-aws-lambda | v0.1.0 |
| <a name="module_lambda_merge_lock"></a> [lambda\_merge\_lock](#module\_lambda\_merge\_lock) | github.com/marshall7m/terraform-aws-lambda | v0.1.0 |
| <a name="module_lambda_trigger_sf"></a> [lambda\_trigger\_sf](#module\_lambda\_trigger\_sf) | github.com/marshall7m/terraform-aws-lambda | v0.1.0 |
| <a name="module_sf_role"></a> [sf\_role](#module\_sf\_role) | github.com/marshall7m/terraform-aws-iam//modules/iam-role | v0.1.0 |

## Resources

| Name | Type |
|------|------|
| [aws_api_gateway_account.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_account) | resource |
| [aws_api_gateway_integration.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration) | resource |
| [aws_api_gateway_integration_response.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration_response) | resource |
| [aws_api_gateway_method.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method) | resource |
| [aws_api_gateway_method_response.response_200](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method_response) | resource |
| [aws_api_gateway_method_settings.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method_settings) | resource |
| [aws_api_gateway_resource.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_resource) | resource |
| [aws_api_gateway_rest_api.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_rest_api) | resource |
| [aws_cloudwatch_event_rule.codebuild_terra_run](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.sf_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.codebuild_terra_run](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.sf_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_iam_policy.ci_metadb_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.lambda_approval_request](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.merge_lock_github_token_ssm_read_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.merge_lock_ssm_param_full_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_rds_cluster.metadb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster) | resource |
| [aws_secretsmanager_secret.ci_metadb_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.master_metadb_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.ci_metadb_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.master_metadb_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_ses_email_identity.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ses_email_identity) | resource |
| [aws_ses_identity_policy.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ses_identity_policy) | resource |
| [aws_ses_template.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ses_template) | resource |
| [aws_sfn_state_machine.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_ssm_parameter.merge_lock](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.merge_lock_github_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.metadb_ci_password](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [github_branch_protection.merge_lock](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/branch_protection) | resource |
| [null_resource.lambda_approval_response_deps](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.lambda_merge_lock_deps](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.lambda_trigger_sf_deps](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.metadb_setup](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [random_id.metadb_users](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [archive_file.lambda_approval_request](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_approval_response](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_approval_response_deps](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_merge_lock](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_merge_lock_deps](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_trigger_sf](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_trigger_sf_deps](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ci_metadb_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_approval_request](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.merge_lock_github_token_ssm_read_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.merge_lock_ssm_param_full_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ses_email_identity.approval](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ses_email_identity) | data source |
| [aws_ssm_parameter.merge_lock_github_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [github_repository.build_scripts](https://registry.terraform.io/providers/integrations/github/latest/docs/data-sources/repository) | data source |
| [github_repository.this](https://registry.terraform.io/providers/integrations/github/latest/docs/data-sources/repository) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_account_parent_cfg"></a> [account\_parent\_cfg](#input\_account\_parent\_cfg) | AWS account-level configurations.<br>  - name: AWS account name (e.g. dev, staging, prod, etc.)<br>  - path: Parent account directory path relative to the repository's root directory path (e.g. infrastructure-live/dev-account)<br>  - voters: List of email addresses that will be sent approval request to<br>  - min\_approval\_count: Minimum approval count needed for CI pipeline to run deployment<br>  - min\_rejection\_count: Minimum rejection count needed for CI pipeline to decline deployment<br>  - dependencies: List of AWS account names that this account depends on before running any of it's deployments <br>    - For example, if the `dev` account depends on the `shared-services` account and both accounts contain infrastructure changes within a PR (rare scenario but possible),<br>      all deployments that resolve infrastructure changes within `shared-services` need to be applied before any `dev` deployments are executed. This is useful given a<br>      scenario where resources within the `dev` account are explicitly dependent on resources within the `shared-serives` account.<br>  - plan\_role\_arn: IAM role ARN within the account that the plan build will assume<br>    - **CAUTION: Do not give the plan role broad administrative permissions as that could lead to detrimental results if the build was compromised**<br>  - deploy\_role\_arn: IAM role ARN within the account that the deploy build will assume<br>    - Fine-grained permissions for each Terragrunt directory within the account can be used by defining a before\_hook block that<br>      conditionally defines that assume\_role block within the directory dependant on the Terragrunt command. For example within `prod/iam/terragrunt.hcl`,<br>      define a before hook block that passes a strict read-only role ARN for `terragrunt plan` commands and a strict write role ARN for `terragrunt apply`. Then<br>      within the `deploy_role_arn` attribute here, define a IAM role that can assume both of these roles. | <pre>list(object({<br>    name                = string<br>    path                = string<br>    voters              = list(string)<br>    min_approval_count  = number<br>    min_rejection_count = number<br>    dependencies        = list(string)<br>    plan_role_arn       = string<br>    deploy_role_arn     = string<br>  }))</pre> | n/a | yes |
| <a name="input_api_stage_name"></a> [api\_stage\_name](#input\_api\_stage\_name) | API deployment stage name | `string` | `"prod"` | no |
| <a name="input_approval_request_sender_email"></a> [approval\_request\_sender\_email](#input\_approval\_request\_sender\_email) | Email address to use for sending approval requests | `string` | n/a | yes |
| <a name="input_base_branch"></a> [base\_branch](#input\_base\_branch) | Base branch for repository that all PRs will compare to | `string` | `"master"` | no |
| <a name="input_build_img"></a> [build\_img](#input\_build\_img) | Docker, ECR or AWS CodeBuild managed image to use for the CodeBuild projects. If not specified, Terraform module will create an ECR image for them. | `string` | `null` | no |
| <a name="input_build_tags"></a> [build\_tags](#input\_build\_tags) | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| <a name="input_codebuild_common_env_vars"></a> [codebuild\_common\_env\_vars](#input\_codebuild\_common\_env\_vars) | Common env vars defined within all Codebuild projects. Useful for setting Terragrunt specific env vars required to run Terragrunt commands. | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| <a name="input_codebuild_source_auth_token"></a> [codebuild\_source\_auth\_token](#input\_codebuild\_source\_auth\_token) | GitHub personal access token used to authorize CodeBuild projects to clone GitHub repos within the Terraform AWS provider's AWS account and region. <br>  If not specified, existing CodeBuild OAUTH or GitHub personal access token authorization is required beforehand. | `string` | `null` | no |
| <a name="input_create_deploy_stack_graph_scan"></a> [create\_deploy\_stack\_graph\_scan](#input\_create\_deploy\_stack\_graph\_scan) | If true, the create\_deploy\_stack build will use the git detected differences to determine what directories to run Step Function executions for.<br>If false, the build will use terragrunt run-all plan detected differences to determine the executions.<br>Set to false if changes to the terraform resources are also being controlled outside of the repository (e.g AWS console, separate CI pipeline, etc.)<br>which results in need to refresh the terraform remote state to accurately detect changes.<br>Otherwise set to true, given that collecting changes via git will be significantly faster than collecting changes via terragrunt run-all plan. | `bool` | `true` | no |
| <a name="input_create_deploy_stack_status_check_name"></a> [create\_deploy\_stack\_status\_check\_name](#input\_create\_deploy\_stack\_status\_check\_name) | Name of the create deploy stack GitHub status | `string` | `"Create Deploy Stack"` | no |
| <a name="input_create_deploy_stack_vpc_config"></a> [create\_deploy\_stack\_vpc\_config](#input\_create\_deploy\_stack\_vpc\_config) | AWS VPC configurations associated with terra\_run CodeBuild project.<br>Ensure that the configuration allows for outgoing HTTPS traffic. | <pre>object({<br>    vpc_id             = string<br>    subnets            = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| <a name="input_create_merge_lock_github_token_ssm_param"></a> [create\_merge\_lock\_github\_token\_ssm\_param](#input\_create\_merge\_lock\_github\_token\_ssm\_param) | Determines if the merge lock AWS SSM Parameter Store value should be created | `bool` | n/a | yes |
| <a name="input_enable_branch_protection"></a> [enable\_branch\_protection](#input\_enable\_branch\_protection) | Determines if the branch protection rule is created. If the repository is private (most likely), the GitHub account associated with<br>the GitHub provider must be registered as a GitHub Pro, GitHub Team, GitHub Enterprise Cloud, or GitHub Enterprise Server account. See here for details: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches | `bool` | `true` | no |
| <a name="input_enforce_admin_branch_protection"></a> [enforce\_admin\_branch\_protection](#input\_enforce\_admin\_branch\_protection) | Determines if the branch protection rule is enforced for the GitHub repository's admins. <br>  This essentially gives admins permission to force push to the trunk branch and can allow their infrastructure-related commits to bypass the CI pipeline. | `bool` | `false` | no |
| <a name="input_file_path_pattern"></a> [file\_path\_pattern](#input\_file\_path\_pattern) | Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension. | `string` | `".+\\.(hcl|tf)$"` | no |
| <a name="input_github_token_ssm_tags"></a> [github\_token\_ssm\_tags](#input\_github\_token\_ssm\_tags) | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| <a name="input_github_webhook_validator_github_token_ssm_description"></a> [github\_webhook\_validator\_github\_token\_ssm\_description](#input\_github\_webhook\_validator\_github\_token\_ssm\_description) | Github token SSM parameter description | `string` | `"Github token used by Github Webhook Validator Lambda Function"` | no |
| <a name="input_github_webhook_validator_github_token_ssm_key"></a> [github\_webhook\_validator\_github\_token\_ssm\_key](#input\_github\_webhook\_validator\_github\_token\_ssm\_key) | AWS SSM Parameter Store key for sensitive Github personal token used by the Github Webhook Validator Lambda Function | `string` | `null` | no |
| <a name="input_github_webhook_validator_github_token_ssm_tags"></a> [github\_webhook\_validator\_github\_token\_ssm\_tags](#input\_github\_webhook\_validator\_github\_token\_ssm\_tags) | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| <a name="input_github_webhook_validator_github_token_ssm_value"></a> [github\_webhook\_validator\_github\_token\_ssm\_value](#input\_github\_webhook\_validator\_github\_token\_ssm\_value) | Registered Github webhook token associated with the Github provider. The token will be used by the Github Webhook Validator Lambda Function.<br>If not provided, module looks for pre-existing SSM parameter via `var.github_webhook_validator_github_token_ssm_key`".<br>GitHub token needs the `repo` permission to access the private repo. (see more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps) | `string` | `""` | no |
| <a name="input_lambda_approval_request_vpc_config"></a> [lambda\_approval\_request\_vpc\_config](#input\_lambda\_approval\_request\_vpc\_config) | VPC configuration for Lambda approval request function.<br>Ensure that the configuration allows for outgoing HTTPS traffic. | <pre>object({<br>    subnet_ids         = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| <a name="input_lambda_approval_response_vpc_config"></a> [lambda\_approval\_response\_vpc\_config](#input\_lambda\_approval\_response\_vpc\_config) | VPC configuration for Lambda approval response function.<br>Ensure that the configuration allows for outgoing HTTPS traffic. | <pre>object({<br>    subnet_ids         = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| <a name="input_lambda_trigger_sf_vpc_config"></a> [lambda\_trigger\_sf\_vpc\_config](#input\_lambda\_trigger\_sf\_vpc\_config) | VPC configuration for Lambda trigger\_sf function.<br>Ensure that the configuration allows for outgoing HTTPS traffic. | <pre>object({<br>    subnet_ids         = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| <a name="input_merge_lock_github_token_ssm_description"></a> [merge\_lock\_github\_token\_ssm\_description](#input\_merge\_lock\_github\_token\_ssm\_description) | Github token SSM parameter description | `string` | `"Github token used by Merge Lock Lambda Function"` | no |
| <a name="input_merge_lock_github_token_ssm_key"></a> [merge\_lock\_github\_token\_ssm\_key](#input\_merge\_lock\_github\_token\_ssm\_key) | AWS SSM Parameter Store key for sensitive Github personal token used by the Merge Lock Lambda Function | `string` | `null` | no |
| <a name="input_merge_lock_github_token_ssm_value"></a> [merge\_lock\_github\_token\_ssm\_value](#input\_merge\_lock\_github\_token\_ssm\_value) | Registered Github webhook token associated with the Github provider. The token will be used by the Merge Lock Lambda Function.<br>If not provided, module looks for pre-existing SSM parameter via `var.merge_lock_github_token_ssm_key`".<br>GitHub token only needs the `repo:status` permission. (see more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps) | `string` | `""` | no |
| <a name="input_merge_lock_status_check_name"></a> [merge\_lock\_status\_check\_name](#input\_merge\_lock\_status\_check\_name) | Name of the merge lock GitHub status | `string` | `"Merge Lock"` | no |
| <a name="input_metadb_availability_zones"></a> [metadb\_availability\_zones](#input\_metadb\_availability\_zones) | AWS availability zones that the metadb RDS cluster will be hosted in. Recommended to define atleast 3 zones. | `list(string)` | `null` | no |
| <a name="input_metadb_ci_password"></a> [metadb\_ci\_password](#input\_metadb\_ci\_password) | Password for the metadb user used for the Codebuild projects | `string` | n/a | yes |
| <a name="input_metadb_ci_username"></a> [metadb\_ci\_username](#input\_metadb\_ci\_username) | Name of the metadb user used for the Codebuild projects | `string` | `"ci_user"` | no |
| <a name="input_metadb_password"></a> [metadb\_password](#input\_metadb\_password) | Master password for the metadb | `string` | n/a | yes |
| <a name="input_metadb_port"></a> [metadb\_port](#input\_metadb\_port) | Port for AWS RDS Postgres db | `number` | `5432` | no |
| <a name="input_metadb_schema"></a> [metadb\_schema](#input\_metadb\_schema) | Schema for AWS RDS Postgres db | `string` | `"prod"` | no |
| <a name="input_metadb_security_group_ids"></a> [metadb\_security\_group\_ids](#input\_metadb\_security\_group\_ids) | AWS VPC security group to associate the metadb with | `list(string)` | `[]` | no |
| <a name="input_metadb_subnets_group_name"></a> [metadb\_subnets\_group\_name](#input\_metadb\_subnets\_group\_name) | AWS VPC subnet group name to associate the metadb with | `string` | `null` | no |
| <a name="input_metadb_username"></a> [metadb\_username](#input\_metadb\_username) | Master username of the metadb | `string` | `"root"` | no |
| <a name="input_pr_approval_count"></a> [pr\_approval\_count](#input\_pr\_approval\_count) | Number of GitHub approvals required to merge a PR with infrastructure changes | `number` | `null` | no |
| <a name="input_pr_plan_env_vars"></a> [pr\_plan\_env\_vars](#input\_pr\_plan\_env\_vars) | Environment variables that will be provided to open PR's Terraform planning builds | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| <a name="input_pr_plan_status_check_name"></a> [pr\_plan\_status\_check\_name](#input\_pr\_plan\_status\_check\_name) | Name of the CodeBuild pr\_plan GitHub status | `string` | `"Plan"` | no |
| <a name="input_pr_plan_vpc_config"></a> [pr\_plan\_vpc\_config](#input\_pr\_plan\_vpc\_config) | AWS VPC configurations associated with PR planning CodeBuild project. <br>Ensure that the configuration allows for outgoing HTTPS traffic. | <pre>object({<br>    vpc_id             = string<br>    subnets            = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Prefix to attach to all resources | `string` | `null` | no |
| <a name="input_repo_name"></a> [repo\_name](#input\_repo\_name) | Name of the pre-existing GitHub repository that is owned by the Github provider | `string` | n/a | yes |
| <a name="input_send_verification_email"></a> [send\_verification\_email](#input\_send\_verification\_email) | Determines if an email verification should be sent to the var.approval\_request\_sender\_email address. Set<br>  to true if the email address is not already authorized to send emails via AWS SES. | `bool` | `true` | no |
| <a name="input_step_function_name"></a> [step\_function\_name](#input\_step\_function\_name) | Name of AWS Step Function machine | `string` | `"deployment-flow"` | no |
| <a name="input_terra_run_env_vars"></a> [terra\_run\_env\_vars](#input\_terra\_run\_env\_vars) | Environment variables that will be provided for tf plan/apply builds | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| <a name="input_terra_run_vpc_config"></a> [terra\_run\_vpc\_config](#input\_terra\_run\_vpc\_config) | AWS VPC configurations associated with terra\_run CodeBuild project. <br>Ensure that the configuration allows for outgoing HTTPS traffic. | <pre>object({<br>    vpc_id             = string<br>    subnets            = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| <a name="input_terraform_version"></a> [terraform\_version](#input\_terraform\_version) | Terraform version used for create\_deploy\_stack and terra\_run builds.<br>Version must be >= `0.13.0`.<br>If repo contains a variety of version constraints, implementing a <br>version manager is recommended (e.g. tfenv). | `string` | `""` | no |
| <a name="input_terragrunt_version"></a> [terragrunt\_version](#input\_terragrunt\_version) | Terragrunt version used for create\_deploy\_stack and terra\_run builds.<br>Version must be >= `0.31.0`.<br>If repo contains a variety of version constraints, implementing a <br>version manager is recommended (e.g. tgswitch). | `string` | `""` | no |
| <a name="input_tf_state_read_access_policy"></a> [tf\_state\_read\_access\_policy](#input\_tf\_state\_read\_access\_policy) | AWS IAM policy ARN that allows create\_deploy\_stack Codebuild project to read from Terraform remote state resource | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_approval_request_function_name"></a> [approval\_request\_function\_name](#output\_approval\_request\_function\_name) | Name of the Lambda Function used for sending approval requests |
| <a name="output_approval_request_log_group_name"></a> [approval\_request\_log\_group\_name](#output\_approval\_request\_log\_group\_name) | Cloudwatch log group associated with the Lambda Function used for processing deployment approval responses |
| <a name="output_approval_url"></a> [approval\_url](#output\_approval\_url) | API URL used for requesting deployment approvals |
| <a name="output_base_branch"></a> [base\_branch](#output\_base\_branch) | Base branch for repository that all PRs will compare to |
| <a name="output_codebuild_create_deploy_stack_arn"></a> [codebuild\_create\_deploy\_stack\_arn](#output\_codebuild\_create\_deploy\_stack\_arn) | ARN of the CodeBuild project that creates the deployment records within the metadb |
| <a name="output_codebuild_create_deploy_stack_name"></a> [codebuild\_create\_deploy\_stack\_name](#output\_codebuild\_create\_deploy\_stack\_name) | Name of the CodeBuild project that creates the deployment records within the metadb |
| <a name="output_codebuild_create_deploy_stack_role_arn"></a> [codebuild\_create\_deploy\_stack\_role\_arn](#output\_codebuild\_create\_deploy\_stack\_role\_arn) | IAM role ARN of the CodeBuild project that creates the deployment records within the metadb |
| <a name="output_codebuild_pr_plan_name"></a> [codebuild\_pr\_plan\_name](#output\_codebuild\_pr\_plan\_name) | Codebuild project name used for creating Terraform plans for new/modified configurations within PRs |
| <a name="output_codebuild_pr_plan_role_arn"></a> [codebuild\_pr\_plan\_role\_arn](#output\_codebuild\_pr\_plan\_role\_arn) | IAM role ARN of the CodeBuild project that creates Terraform plans for new/modified configurations within PRs |
| <a name="output_codebuild_terra_run_arn"></a> [codebuild\_terra\_run\_arn](#output\_codebuild\_terra\_run\_arn) | ARN of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow |
| <a name="output_codebuild_terra_run_name"></a> [codebuild\_terra\_run\_name](#output\_codebuild\_terra\_run\_name) | Name of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow |
| <a name="output_codebuild_terra_run_role_arn"></a> [codebuild\_terra\_run\_role\_arn](#output\_codebuild\_terra\_run\_role\_arn) | IAM role ARN of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow |
| <a name="output_lambda_trigger_sf_arn"></a> [lambda\_trigger\_sf\_arn](#output\_lambda\_trigger\_sf\_arn) | ARN of the Lambda Function used for triggering Step Function execution(s) |
| <a name="output_merge_lock_github_webhook_id"></a> [merge\_lock\_github\_webhook\_id](#output\_merge\_lock\_github\_webhook\_id) | GitHub webhook ID used for sending pull request activity to the API to be processed by the merge lock Lambda Function |
| <a name="output_merge_lock_ssm_key"></a> [merge\_lock\_ssm\_key](#output\_merge\_lock\_ssm\_key) | SSM Parameter Store key used for storing the current PR ID that has been merged and is being process by the CI flow |
| <a name="output_merge_lock_status_check_name"></a> [merge\_lock\_status\_check\_name](#output\_merge\_lock\_status\_check\_name) | Context name of the merge lock GitHub status check |
| <a name="output_metadb_arn"></a> [metadb\_arn](#output\_metadb\_arn) | ARN for the metadb |
| <a name="output_metadb_ci_password"></a> [metadb\_ci\_password](#output\_metadb\_ci\_password) | Password used by CI services to connect to the metadb |
| <a name="output_metadb_ci_username"></a> [metadb\_ci\_username](#output\_metadb\_ci\_username) | Username used by CI services to connect to the metadb |
| <a name="output_metadb_endpoint"></a> [metadb\_endpoint](#output\_metadb\_endpoint) | AWS RDS endpoint for the metadb |
| <a name="output_metadb_name"></a> [metadb\_name](#output\_metadb\_name) | Name of the metadb |
| <a name="output_metadb_password"></a> [metadb\_password](#output\_metadb\_password) | Master password for the metadb |
| <a name="output_metadb_port"></a> [metadb\_port](#output\_metadb\_port) | Port used for the metadb |
| <a name="output_metadb_secret_manager_ci_arn"></a> [metadb\_secret\_manager\_ci\_arn](#output\_metadb\_secret\_manager\_ci\_arn) | Secret Manager ARN of the metadb CI user credentials |
| <a name="output_metadb_secret_manager_master_arn"></a> [metadb\_secret\_manager\_master\_arn](#output\_metadb\_secret\_manager\_master\_arn) | Secret Manager ARN of the metadb master user credentials |
| <a name="output_metadb_username"></a> [metadb\_username](#output\_metadb\_username) | Master username for the metadb |
| <a name="output_step_function_arn"></a> [step\_function\_arn](#output\_step\_function\_arn) | ARN of the Step Function |
| <a name="output_step_function_name"></a> [step\_function\_name](#output\_step\_function\_name) | Name of the Step Function |
| <a name="output_trigger_sf_function_name"></a> [trigger\_sf\_function\_name](#output\_trigger\_sf\_function\_name) | Name of the Lambda Function used for triggering Step Function execution(s) |
| <a name="output_trigger_sf_log_group_name"></a> [trigger\_sf\_log\_group\_name](#output\_trigger\_sf\_log\_group\_name) | Cloudwatch log group associated with the Lambda Function used for triggering Step Function execution(s) |
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
 
# Deploy the Terraform Module

## Prerequistes
- CodeBuild within the AWS account and region that the Terraform module is deployed to must have access to the GitHub account associated with the repo specified under `var.repo_name` via OAuth or personal access token. See here for more details: https://docs.aws.amazon.com/codebuild/latest/userguide/access-tokens.html

 
For a demo of the module that will cleanup any resources created, see the `Integration` section of this README. The steps below are meant for implementing the module into your current AWS ecosystem.
1. Open a terragrunt `.hcl` or terraform `.tf` file
2. Create a module block using this repo as the source
3. Fill in the required module variables
4. Run `terraform init` to download the module
5. Run `terraform plan` to see what resources will be created
6. Run `terraform apply` and enter `yes` to the approval prompt
7. Refill coffee and wait for resources to be created
8. Go to the `var.approval_request_sender_email` email address. Find the AWS SES verification email (subject should be something like "Amazon Web Services – Email Address Verification Request in region US West (Oregon)") and click on the verification link.
8. Create a PR with changes to the target repo defined under `var.repo_name` that will create a difference in the Terraform configuration's tfstate file
9. Merge the PR
10. Wait for the approval email to be sent to the voter's email address
11. Login into the voter's email address and open the approval request email (subject should be something like "${var.step_function_name} - Need Approval for Path: {{path}}")
12. Choose either to approval or reject the deployment and click on the submit button
13. Wait for the deployment build to finish
14. Verify that the Terraform changes have been deployed

## Testing
### Option 1: Docker Environment

#### Requirements
 
The following tools are required:
- [git](https://github.com/git/git)
- [docker](https://docs.docker.com/get-docker/)

The steps below will setup a testing Docker environment for running tests.

1. Clone this repo by running the CLI command: `git clone https://github.com/marshall7m/terraform-aws-infrastructure-live-ci.git`
2. Within your CLI, change into the root of the repo
3. Ensure that the environment variables from the `docker-compose.yml` file's `environment:` section are set. For a description of the `TF_VAR_*` variables, see the `tests/unit/variables.tf` and `tests/integration/variables.tf` files.
4. Run `docker-compose run --rm unit /bin/bash` to setup a docker environment for unit testing or run `docker-compose run --rm integration /bin/bash` to setup a docker environment for integration testing. The command will create an interactive shell within the docker container.
5. Run tests within the `tests` directory

```
NOTE: All Terraform resources will automatically be deleted during the PyTest session cleanup. If the provisioned resources are needed after the PyTest execution,
use the `--skip-tf-destroy` flag (e.g. `pytest tests/integration --skip-tf-destroy`). BEWARE: If the resources are left alive after the tests, the AWS account may incur additional charges.
```

### Option 2: Local GitHub Actions Workflow via [act](https://github.com/nektos/act)

#### Requirements
 
The following tools are required:
- [git](https://github.com/git/git)
- [docker](https://docs.docker.com/get-docker/)
- [act](https://github.com/nektos/act)

The steps below will run the GitHub Actions workflow within local Docker containers.

1. Clone this repo by running the CLI command: `git clone https://github.com/marshall7m/terraform-aws-infrastructure-live-ci.git`
2. Within your CLI, change into the root of the repo
3. Run the following commmand: `act push`. This will run the GitHub workflow logic for push events
4. A prompt will arise requesting GitHub Action secrets needed to run the workflow. Fill in the secrets accordingly. The secrets can be set via environment variables to skip the prompt. For a description of the `TF_VAR_*` variables, see the `tests/unit/variables.tf` and `tests/integration/variables.tf` files.

```
NOTE: All Terraform resources will automatically be deleted during the PyTest session cleanup
```

## Pitfalls

- Management of two GitHub Personal Access Tokens (PAT). User is required to refresh the GitHub token values when the expiration date is close.
  - Possibly create a GitHub machine user and add as a collaborator to the repo to remove need to renew token expiration? User would specify a pre-existing machine user or the module can create a machine user (would require a TF local-exec script to create the user)

# TODO:
 
### Features:

- [ ] Create a feature for handling deleted terragrunt folder using git diff commands
- [ ] Create a feature for handling migrated terragrunt directories using git diff commands / tf state pull
- [ ] Approval voter can choose to be notified when deployment stack and/or deployment execution is successful or failed

### Improvements:

- [ ] create aesthetically pleasing approval request HTML template
- [ ] Allow GRAPH_SCAN to be toggled on a PR-level without having to change via Terraform module/CodeBuild console