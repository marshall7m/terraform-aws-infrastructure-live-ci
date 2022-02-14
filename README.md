# Terraform AWS Infrastructure Live CI

## Problem

`terragrunt run-all xxx` commands have a limitation of inaccurately outputting the dependency values for child terraform configurations if the parent terraform configuration changes. The current advice is to exclude `terragrunt run-all xxx` from CI systems and run individual `terragrunt xxx` within each target directory. This imposes the tedious process of manually updating what directories to run on and the explicit ordering between them within the CI pipeline. 


## Use Cases


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
| account\_parent\_cfg | Any modified child filepath of the parent path will be processed within the parent path associated Map task | <pre>list(object({<br>    name                = string<br>    path                = string<br>    voters              = list(string)<br>    min_approval_count  = number<br>    min_rejection_count = number<br>    dependencies        = list(string)<br>  }))</pre> | n/a | yes |
| api\_name | Name of AWS Rest API | `string` | `null` | no |
| apply\_role\_assumable\_role\_arns | List of IAM role ARNs the apply CodeBuild action can assume | `list(string)` | `[]` | no |
| apply\_role\_name | Name of the IAM role used for running terr\* apply commands | `string` | `null` | no |
| apply\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the apply Codebuild action | `list(string)` | `[]` | no |
| approval\_request\_sender\_email | Email address to use for sending approval requests | `string` | n/a | yes |
| base\_branch | Base branch for repository that all PRs will compare to | `string` | `"master"` | no |
| build\_tags | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| cloudwatch\_event\_rule\_name | Name of the CloudWatch event rule that detects when the Step Function completes an execution | `string` | `null` | no |
| codebuild\_common\_env\_vars | Common env vars defined within all Codebuild projects. Useful for setting Terragrunt specific env vars required to run Terragrunt commmands. | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | n/a | yes |
| codebuild\_common\_policy\_arns | Common AWS IAM policy ARNs to attach to all Codebuild project roles | `list(string)` | `[]` | no |
| codebuild\_vpc\_config | AWS VPC configurations associated with all CodeBuild projects within this module. <br>The subnets must have the approriate security groups to reach the subnet that the db is associated with.<br>Ensure that there are enough IP addresses within the subnet to host the two codebuild projects. | <pre>object({<br>    vpc_id  = string<br>    subnets = list(string)<br>  })</pre> | n/a | yes |
| common\_tags | Tags to add to all resources | `map(string)` | `{}` | no |
| create\_github\_token\_ssm\_param | Determines if an AWS System Manager Parameter Store value should be created for the Github token | `bool` | `true` | no |
| enable\_metadb\_http\_endpoint | Enables AWS SDK connection to the metadb via data API HTTP endpoint. Needed in order to connect to metadb from outside of metadb's associated VPC | `bool` | `false` | no |
| file\_path\_pattern | Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension. | `string` | `".+\\.(hcl|tf)$"` | no |
| github\_token\_ssm\_description | Github token SSM parameter description | `string` | `"Github token used for setting PR merge locks for live infrastructure repo"` | no |
| github\_token\_ssm\_key | AWS SSM Parameter Store key for sensitive Github personal token | `string` | `"github-webhook-validator-token"` | no |
| github\_token\_ssm\_tags | Tags for Github token SSM parameter | `map(string)` | `{}` | no |
| github\_token\_ssm\_value | Registered Github webhook token associated with the Github provider. If not provided, module looks for pre-existing SSM parameter via `github_token_ssm_key` | `string` | `""` | no |
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
| metadb\_security\_group\_ids | AWS VPC security group to associate the metadb with. Must allow inbound traffic from the subnet(s) that the Codebuild projects are associated with under `var.codebuild_vpc_config` | `list(string)` | `[]` | no |
| metadb\_subnets\_group\_name | AWS VPC subnet group name to associate the metadb with | `string` | n/a | yes |
| metadb\_username | Master username of the metadb | `string` | `"root"` | no |
| plan\_role\_assumable\_role\_arns | List of IAM role ARNs the plan CodeBuild action can assume | `list(string)` | `[]` | no |
| plan\_role\_name | Name of the IAM role used for running terr\* plan commands | `string` | `null` | no |
| plan\_role\_policy\_arns | List of IAM policy ARNs that will be attach to the plan Codebuild action | `list(string)` | `[]` | no |
| repo\_full\_name | Full name of the GitHub repository in the form of `user/repo` | `string` | n/a | yes |
| step\_function\_name | Name of AWS Step Function machine | `string` | `"infrastructure-live-ci"` | no |
| terra\_run\_build\_name | Name of AWS CodeBuild project that will run Terraform commmands withing Step Function executions | `string` | `null` | no |
| terra\_run\_env\_vars | Environment variables that will be provided for tf plan/apply builds | <pre>list(object({<br>    name  = string<br>    value = string<br>    type  = optional(string)<br>  }))</pre> | `[]` | no |
| terra\_run\_img | Docker, ECR or AWS CodeBuild managed image to use for the terra\_run CodeBuild project that runs plan/apply commands | `string` | `null` | no |
| terraform\_version | Terraform version used for trigger\_sf and terra\_run builds. If repo contains a variety of version constraints, implementing a dynamic version manager (e.g. tfenv) is recommended | `string` | `"1.0.2"` | no |
| terragrunt\_version | Terragrunt version used for trigger\_sf and terra\_run builds | `string` | `"0.31.0"` | no |
| trigger\_step\_function\_build\_name | Name of AWS CodeBuild project that will trigger the AWS Step Function | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| codebuild\_merge\_lock\_arn | n/a |
| codebuild\_merge\_lock\_name | n/a |
| codebuild\_trigger\_sf\_arn | n/a |
| codebuild\_trigger\_sf\_name | n/a |
| metadb\_address | n/a |
| metadb\_arn | n/a |
| metadb\_ci\_password | n/a |
| metadb\_ci\_username | n/a |
| metadb\_endpoint | n/a |
| metadb\_name | n/a |
| metadb\_password | n/a |
| metadb\_port | n/a |
| metadb\_secret\_manager\_master\_arn | n/a |
| metadb\_username | n/a |
| sf\_arn | n/a |

<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->


# Testing

## Integration

### Requirements

# TODO:
