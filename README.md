# Terraform AWS Infrastructure Live CI
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

## Problem

`terragrunt run-all xxx` commands have a limitation of inaccurately outputting the dependency values for child terraform configurations if the parent terraform configuration changes. The current advice is to exclude `terragrunt run-all xxx` from CI systems and run individual `terragrunt xxx` within each target directory. This imposes the tedious process of manually updating what directories to run on and the explicit ordering between them within the CI pipeline. 

## 

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 0.14.0 |
| aws | >= 3.22 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 3.22 |
| random | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_id | AWS account id | `number` | n/a | yes |
| artifact\_bucket\_force\_destroy | Determines if all bucket content will be deleted if the bucket is deleted (error-free bucket deletion) | `bool` | `false` | no |
| artifact\_bucket\_name | Name of the artifact S3 bucket to be created or the name of a pre-existing bucket name to be used for storing the pipeline's artifacts | `any` | `null` | no |
| artifact\_bucket\_tags | Tags to attach to provisioned S3 bucket | `map(string)` | `{}` | no |
| branch | Repo branch the pipeline is associated with | `string` | `"master"` | no |
| build\_assumable\_role\_arns | AWS ARNs the CodeBuild role can assume | `list(string)` | `[]` | no |
| build\_env\_vars | Base environment variables that will be provided for each CodePipeline action build | <pre>list(object({<br>    name = string<br>    value = string<br>    type = optional(string)<br>  }))</pre> | `[]` | no |
| build\_name | CodeBuild project name | `string` | `"infrastructure-live-ci"` | no |
| build\_tags | Tags to attach to AWS CodeBuild project | `map(string)` | `{}` | no |
| buildspec | CodeBuild buildspec path relative to the source repo root directory | `string` | `null` | no |
| cmk\_arn | ARN of a pre-existing CMK to use for encrypting CodePipeline artifacts at rest | `string` | `null` | no |
| codestar\_conn | AWS CodeStar connection configuration used to define the source stage of the pipeline | <pre>object({<br>    name = string<br>    provider = string<br>  })</pre> | <pre>{<br>  "name": "github-conn",<br>  "provider": "GitHub"<br>}</pre> | no |
| common\_tags | Tags to add to all resources | `map(string)` | `{}` | no |
| enabled | Determines if module should create resources or destroy pre-existing resources managed by this module | `bool` | `true` | no |
| pipeline\_name | Pipeline name | `string` | `"infrastructure-live-ci-pipeline"` | no |
| pipeline\_tags | Tags to attach to the pipeline | `map(string)` | `{}` | no |
| repo\_id | Source repo ID with the following format: owner/repo | `string` | `null` | no |
| role\_arn | Pre-existing IAM role ARN to use for the CodePipeline | `string` | `null` | no |
| role\_description | n/a | `string` | `"Allows Amazon Codepipeline to call AWS services on your behalf"` | no |
| role\_force\_detach\_policies | Determines attached policies to the CodePipeline service roles should be forcefully detached if the role is destroyed | `bool` | `false` | no |
| role\_max\_session\_duration | Max session duration (seconds) the role can be assumed for | `number` | `3600` | no |
| role\_path | Path to create policy | `string` | `"/"` | no |
| role\_permissions\_boundary | Permission boundary policy ARN used for CodePipeline service role | `string` | `""` | no |
| role\_tags | Tags to add to CodePipeline service role | `map(string)` | `{}` | no |
| stages | List of pipeline stages (see: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codepipeline) | <pre>list(object({<br>    name = string<br>    order = number<br>    paths = list(string)<br>    tf_plan_role_arn = optional(string)<br>    tf_apply_role_arn = optional(string)<br>  }))</pre> | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| codebuild\_arn | n/a |
| codebuild\_role\_arn | n/a |
| codepipeline\_arn | n/a |
| codepipeline\_role\_arn | n/a |
| codestar\_arn | n/a |

<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->