#!/bin/bash
if [ -n "${TERRAFORM_VERSION}" ]; then
    echo "Installing Terraform version via tfenv: ${TERRAFORM_VERSION}"
    tfenv install "${TERRAFORM_VERSION}"
    tfenv use "${TERRAFORM_VERSION}"
fi
echo "Terraform Version: $(terraform --version)"

if [ -n "${TERRAGRUNT_VERSION}" ]; then
    echo "Installing Terragrunt version via tgswitch: ${TERRAGRUNT_VERSION}"
    tgswitch "${TERRAGRUNT_VERSION}"
fi
echo "Terragrunt Version: $(terragrunt --version)"

echo "Cloning source repo URL: $SOURCE_CLONE_URL"
# TODO: cd into source repo
git clone -b "$SOURCE_VERSION" --single-branch "$SOURCE_CLONE_URL" source-repo
cd source-repo || exit 1

echo "PWD: $PWD"

exec "$@"
