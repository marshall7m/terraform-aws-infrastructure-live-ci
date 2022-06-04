#!/bin/bash
if [ -n "${TERRAFORM_VERSION}" ]; then
    echo "Installing Terraform version via tfenv: ${TERRAFORM_VERSION}"
    tfenv install "${TERRAFORM_VERSION}"
    tfenv use "${TERRAFORM_VERSION}"
fi
echo "Terraform Version: $(terraform --version)"

if [ -n "${TERRAGRUNT_VERSION}" ]; then
    echo "Installing Terragrunt version via tgenv: ${TERRAGRUNT_VERSION}"
    tgenv install "${TERRAGRUNT_VERSION}"
    tgenv use "${TERRAGRUNT_VERSION}"
fi
echo "Terragrunt Version: $(terragrunt --version)"