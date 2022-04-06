# Terraform AWS Infrastructure Live CI

## Problem

`terragrunt run-all xxx` commands have a limitation of inaccurately outputting the dependency values for child terraform configurations if the parent terraform configuration changes. The current advice is to exclude `terragrunt run-all xxx` from CI systems and run individual `terragrunt xxx` within each target directory. This imposes the tedious process of manually updating what directories to run on and the explicit ordering between them within the CI pipeline. 

TODO: Reference SO/GitHub posts: 

 https://github.com/gruntwork-io/terragrunt/issues/720#issuecomment-497888756

 https://github.com/gruntwork-io/terragrunt/issues/262

## Design

TODO: Insert cloudcraft design architecture here

## Use Cases

- Monolithic repo structure
- Multi AWS account deployments
- Account-level approval management

## Why AWS Step Function for deployment flow?

### Dynamic Conditional Workflow
It would seem like CodePipeline would be a simple and approriate service for hosting the deployment workflow. Given the benefits of integrated
approval flows managed via IAM users/roles, simple and intuitive GUI and .. it seems like a viable option. Even with these benefits, CodePipeline limitation for handling dynamic and conditinal workflows was enough of a reason to use Step Function instread. Step Funciton has the ability to handle complex conditional workflows by using what called [](). Given the output or results of one task, Step Function can dynamically choose what task to run next. 

### Pricing

### Updating Process

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


## CLI Requirements
| Name | Version |
|------|---------|
| awscli | >= 1.22.5 |
| python3 | >= 3.9 |
| pip | >= 22.0.4 |
| docker | >= 20.10.8 |

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 0.14.0 |
| aws | >= 3.44 |
| github | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| archive | n/a |
| aws | >= 3.44 |
| github | ~> 4.0 |
| null | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_parent\_cfg | AWS account-level configurations.<br>  - name: AWS account name (e.g. dev, staging, prod, etc.)<br>  - path: Parent account directory path relative to the repository's root directory path (e.g. infrastructure-live/dev-account)<br>  - voters: List of email addresses that will be sent approval request to<br>  - min\_approval\_count: Minimum approval count needed for CI pipeline to run deployment<br>  - min\_rejection\_count: Minimum rejection count needed for CI pipeline to decline deployment<br>  - dependencies: List of AWS account names that this account depends on before running any of it's deployments <br>    - For example, if the `dev` account depends on the `shared-services` account and both accounts contain infrastructure changes within a PR (rare scenario but possible),<br>      all deployments that resolve infrastructure changes within `shared-services` need to be applied before any `dev` deployments are executed. This is useful given a<br>      scenario where resources within the `dev` account are explicitly dependent on resources within the `shared-serives` account.<br>  - plan\_role\_arn: IAM role ARN within the account that the plan build will assume<br>    - \*\*CAUTION: Do not give the plan role broad administrative permissions as that could lead to detrimental results if the build was compromised\*\*<br>  - deploy\_role\_arn: IAM role ARN within the account that the deploy build will assume<br>    - Fine-grained permissions for each Terragrunt directory within the account can be used by defining a before\_hook block that<br>      conditionally defines that assume\_role block within the directory dependant on the Terragrunt command. For example within `prod/iam/terragrunt.hcl`,<br>      define a before hook block that passes a strict read-only role ARN for `terragrunt plan` commands and a strict write role ARN for `terragrunt apply`. Then<br>      within the `deploy_role_arn` attribute here, define a IAM role that can assume both of these roles. | <pre>list(object({<br>    name                = string<br>    path                = string<br>    voters              = list(string)<br>    min_approval_count  = number<br>    min_rejection_count = number<br>    dependencies        = list(string)<br>    plan_role_arn       = string<br>    deploy_role_arn     = string<br>  }))</pre> | n/a | yes |
| api\_name | Name of AWS Rest API | `string` | `null` | no |
| api\_stage\_name | API deployment stage name | `string` | `"prod"` | no |
| approval\_request\_sender\_email | Email address to use for sending approval requests | `string` | n/a | yes |
| base\_branch | Base branch for repository that all PRs will compare to | `string` | `"master"` | no |
| build\_tags | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| cloudwatch\_event\_rule\_name | Name of the CloudWatch event rule that detects when the Step Function completes an execution | `string` | `null` | no |
| codebuild\_common\_env\_vars | Common env vars defined within all Codebuild projects. Useful for setting Terragrunt specific env vars required to run Terragrunt commmands. | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | n/a | yes |
| common\_tags | Tags to add to all resources | `map(string)` | `{}` | no |
| create\_deploy\_stack\_build\_name | Name of AWS CodeBuild project that will create the PR deployment stack into the metadb | `string` | `null` | no |
| create\_deploy\_stack\_vpc\_config | AWS VPC configurations associated with terra\_run CodeBuild project. <br>Ensure that the configuration allows for outgoing traffic for downloading associated repository sources from the internet. | <pre>object({<br>    vpc_id             = string<br>    subnets            = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| create\_github\_token\_ssm\_param | Determines if an AWS System Manager Parameter Store value should be created for the Github token | `bool` | `true` | no |
| enable\_metadb\_http\_endpoint | Enables AWS SDK connection to the metadb via data API HTTP endpoint. Needed in order to connect to metadb from outside of metadb's associated VPC | `bool` | `false` | no |
| file\_path\_pattern | Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension. | `string` | `".+\\.(hcl|tf)$"` | no |
| github\_token\_ssm\_description | Github token SSM parameter description | `string` | `"Github token used for setting PR merge locks for live infrastructure repo"` | no |
| github\_token\_ssm\_key | AWS SSM Parameter Store key for sensitive Github personal token | `string` | `"github-webhook-validator-token"` | no |
| github\_token\_ssm\_tags | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| github\_token\_ssm\_value | Registered Github webhook token associated with the Github provider. If not provided, module looks for pre-existing SSM parameter via `github_token_ssm_key` | `string` | `""` | no |
| lambda\_approval\_request\_vpc\_config | VPC configuration for Lambda approval request function | <pre>object({<br>    subnet_ids         = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| lambda\_approval\_response\_vpc\_config | VPC configuration for Lambda approval response function | <pre>object({<br>    subnet_ids         = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| lambda\_trigger\_sf\_vpc\_config | VPC configuration for Lambda trigger\_sf function | <pre>object({<br>    subnet_ids         = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| merge\_lock\_build\_name | Codebuild project name used for determine if infrastructure related PR can be merged into base branch | `string` | `null` | no |
| merge\_lock\_ssm\_key | SSM Parameter Store key used for locking infrastructure related PR merges | `string` | `null` | no |
| metadb\_availability\_zones | AWS availability zones that the metadb RDS cluster will be hosted in. Recommended to define atleast 3 zones. | `list(string)` | `null` | no |
| metadb\_ci\_password | Password for the metadb user used for the Codebuild projects | `string` | n/a | yes |
| metadb\_ci\_username | Name of the metadb user used for the Codebuild projects | `string` | `"ci_user"` | no |
| metadb\_name | Name of the AWS RDS db | `string` | `null` | no |
| metadb\_password | Master password for the metadb | `string` | n/a | yes |
| metadb\_port | Port for AWS RDS Postgres db | `number` | `5432` | no |
| metadb\_publicly\_accessible | Determines if metadb is publicly accessible outside of it's associated VPC | `bool` | `false` | no |
| metadb\_schema | Schema for AWS RDS Postgres db | `string` | `"prod"` | no |
| metadb\_security\_group\_ids | AWS VPC security group to associate the metadb with | `list(string)` | `[]` | no |
| metadb\_subnets\_group\_name | AWS VPC subnet group name to associate the metadb with | `string` | `null` | no |
| metadb\_username | Master username of the metadb | `string` | `"root"` | no |
| prefix | Prefix to attach to all resources | `string` | `null` | no |
| repo\_name | Name of the GitHub repository that is owned by the Github provider | `string` | n/a | yes |
| step\_function\_name | Name of AWS Step Function machine | `string` | `"infrastructure-live-ci"` | no |
| terra\_run\_build\_name | Name of AWS CodeBuild project that will run Terraform commmands withing Step Function executions | `string` | `null` | no |
| terra\_run\_env\_vars | Environment variables that will be provided for tf plan/apply builds | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| terra\_run\_img | Docker, ECR or AWS CodeBuild managed image to use for the terra\_run CodeBuild project that runs plan/apply commands | `string` | `null` | no |
| terra\_run\_vpc\_config | AWS VPC configurations associated with terra\_run CodeBuild project. <br>Ensure that the configuration allows for outgoing traffic for downloading associated repository sources from the internet. | <pre>object({<br>    vpc_id             = string<br>    subnets            = list(string)<br>    security_group_ids = list(string)<br>  })</pre> | `null` | no |
| terraform\_version | Terraform version used for create\_deploy\_stack and terra\_run builds. If repo contains a variety of version constraints, implementing a dynamic version manager (e.g. tfenv) is recommended | `string` | `"1.0.2"` | no |
| terragrunt\_version | Terragrunt version used for create\_deploy\_stack and terra\_run builds | `string` | `"0.31.0"` | no |
| tf\_state\_read\_access\_policy | AWS IAM policy ARN that allows create deploy stack Codebuild project to read from Terraform remote state resource | `string` | n/a | yes |
| trigger\_sf\_function\_name | Name of the AWS Lambda function used to trigger Step Function deployments | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| approval\_request\_log\_group\_name | Cloudwatch log group associated with the Lambda function used for processing deployment approval responses |
| approval\_url | API URL used for requesting deployment approvals |
| base\_branch | Base branch for repository that all PRs will compare to |
| codebuild\_create\_deploy\_stack\_arn | ARN of the CodeBuild project that creates the deployment records within the metadb |
| codebuild\_create\_deploy\_stack\_name | Name of the CodeBuild project that creates the deployment records within the metadb |
| codebuild\_create\_deploy\_stack\_role\_arn | IAM role ARN of the CodeBuild project that creates the deployment records within the metadb |
| codebuild\_terra\_run\_arn | ARN of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow |
| codebuild\_terra\_run\_name | Name of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow |
| codebuild\_terra\_run\_role\_arn | IAM role ARN of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow |
| lambda\_trigger\_sf\_arn | ARN of the Lambda function used for triggering Step Function execution(s) |
| merge\_lock\_github\_webhook\_id | GitHub webhook ID used for sending pull request activity to the API to be processed by the merge lock Lambda function |
| merge\_lock\_ssm\_key | SSM Parameter Store key used for storing the current PR ID that has been merged and is being process by the CI flow |
| metadb\_arn | ARN for the metadb |
| metadb\_ci\_password | Password used by CI services to connect to the metadb |
| metadb\_ci\_username | Username used by CI services to connect to the metadb |
| metadb\_endpoint | AWS RDS endpoint for the metadb |
| metadb\_name | Name of the metadb |
| metadb\_password | Master password for the metadb |
| metadb\_port | Port used for the metadb |
| metadb\_secret\_manager\_master\_arn | Secret Manager ARN of the metadb master user credentials |
| metadb\_username | Master username for the metadb |
| step\_function\_arn | ARN of the Step Function |
| step\_function\_name | Name of the Step Function |
| trigger\_sf\_function\_name | Name of the Lambda function used for triggering Step Function execution(s) |
| trigger\_sf\_log\_group\_name | Cloudwatch log group associated with the Lambda function used for triggering Step Function execution(s) |

<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

# Deploy the Terraform Module

For a demo of the module that will cleanup any resources created, see the `Integration` section of this README. The step below are meant for implementing the module into your current AWS ecosytem.
1. Open a terragrunt `.hcl` or terraform `.tf` file
2. Ensure that the module will be deployed within an AWS account that will have access to roles within other AWS accounts that
2. Create a module block using this repo as the source
3. Fill in the required module variables
4. Run `terraform init` to download the module
5. Run `terraform plan` to see what resources will be created
6. Run `terraform apply` and enter `yes` to the approval prompt
7. Refill coffee and wait for resources to be created
8. Create a PR with changes to the target repo defined under `var.repo_name` that will create a difference in tfstate file
9. Merge the PR
10. Wait for the approval email to be sent to the email associated with the changed directory's tfstate
11. Click either the approval or deny link
12. Check to see if the Terraform changes have been deployed

# Testing

## Integration

### Requirements

The following tools are required:
- [Docker](https://docs.docker.com/get-docker/)

The following environment variables are required to be set:
- AWS Credentials:
    - `AWS_ACCESS_KEY_ID`
    - `AWS_SECRET_ACCESS_KEY`
    - `AWS_REGION`
    - `AWS_DEFAULT_REGION`
    - `AWS_SESSION_TOKEN`
- Github personal access token of the GitHub account that will host dummy GitHub resources
    - `GITHUB_TOKEN`

The steps below will setup a testing Docker environment for running integration tests.

1. Clone this repo by running the CLI command: `git clone https://github.com/marshall7m/mut-terraform-aws-infrastructure-live-ci.git`
2. Within your CLI, change into the root of the repo
3. Ensure that the environment variables for the AWS credentials are set for the AWS account that will provision the Terraform module resources
4. Exec into the testing docker container by running the command: `bash setup.sh --remote`
5. Change to the integration testing directory: `cd tests/integration`
6. To see a simple demo of how the CI pipeline works:
    - If you want to run simple integration test cases run `pytest test_deployments.py`
    - If you want to cleanup all the resouces created after running the tests: `pytest test_deployments.py --tf-destroy` 
7. If you want to run subsequent tests after the initial pytest command, run `pytest test_deployments.py --skip-init --skip-apply` to skip running `terraform init` and `terraform apply` since the resources will still be alive
8. As mentioned above, cleanup any resources created by running a test file with the `--tf-destroy` flag like so: `pytest test_deployments.py --tf-destroy`

# TODO:
- Implement --tf-destroy pytest flag
- Implement --remote and --local setup flags
- Update Lambda Function unit tests