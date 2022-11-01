locals {
  before_hook = <<-EOF
if [[ -z $SKIP_TFENV ]]; then
  echo "Scanning Terraform files for Terraform binary version constraint"
  tfenv use min-required || tfenv install min-required \
    && tfenv use min-required
else
  echo "Skip scanning Terraform files for Terraform binary version constraint"
  echo "Terraform Version: $(tfenv version-name)";
fi
  EOF
}

terraform {
  before_hook "before_hook" {
    commands = ["validate", "init", "plan", "apply", "destroy"]
    execute  = ["bash", "-c", local.before_hook]
  }
}