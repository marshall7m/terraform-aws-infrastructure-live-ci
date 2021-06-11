terraform {
  before_hook "before_hook" {
    commands = ["validate", "plan", "apply"]
    execute  = ["bash", "-c", local.before_hook]
  }
}

locals {
  provider_switches = merge(
    read_terragrunt_config(find_in_parent_folders("provider_switches.hcl", "null.hcl"), {}),
    read_terragrunt_config("provider_switches.hcl", {})
  )

  before_hook = <<-EOF
  %{if try(local.provider_switches.locals.include_github, false)}
  if [[ -z $GITHUB_TOKEN ]]; then
    echo Getting Github Token;
    export GITHUB_TOKEN=$(aws ssm get-parameter --name "infrastructure-modules-ci-github-token" --with-decryption | jq '.Parameter | .Value');
  fi
  %{endif}
  if [[ -z $SKIP_TFENV ]]; then 
  echo Scanning Terraform files for Terraform binary version constraint 
  tfenv use min-required || tfenv install min-required \
  && tfenv use min-required
  else 
  echo Skip scanning Terraform files for Terraform binary version constraint
  tfenv version-name
  fi
  EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "skip"
  contents  = <<-EOF
  %{if try(local.provider_switches.locals.include_github, false)}
  provider "github" {
      owner = "marshall7m"
  }
  %{endif}
  EOF
}

remote_state {
  backend = "local"
  config  = {}
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}