# Version Constraints

| Build | Binary | Version | Reason |
|-------|--------|---------|--------|
| create_deploy_stack | terraform | >= 0.13.0 | With < 0.13.0, create_stack() return results include `\n` between attributes (fixable) |
| create_deploy_stack | terragrunt | >= 0.31.0 | With < 0.31.0, create_stack() returns nothing from parsing run-all plan. With < 0.23.7, `terragrunt graph-dependencies` cli arg is not available |
| terra_run | terraform | >= 0.13.0 | Within older versions, get_new_provider_resources() would need different parsing of the provider attribute from the tfstate file |
| terra_run | terragrunt | >= 0.31.0 | create_deploy_stack requires `terragrunt run-all` |


## Important Terragrunt releases:
- 0.28.1 introduced `terragrunt run-all`
- 0.23.7 introduced `terragrunt graph-dependencies`