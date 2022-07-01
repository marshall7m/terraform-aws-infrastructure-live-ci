#!/bin/bash

set -e

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

export SOURCE_REPO_PATH="$PWD/source-repo"
echo "Cloning source repo URL: $SOURCE_CLONE_URL to path: $SOURCE_REPO_PATH"

git clone -b "$SOURCE_VERSION" --single-branch "$SOURCE_CLONE_URL" "$SOURCE_REPO_PATH"
cd "$SOURCE_REPO_PATH" || exit 1

echo "Current working directory: $PWD"

# TODO: Design guardrails around what commands can be runned from the ecs task
# Either restrict commands only from this docker image's /src (user won't be able to customize task execution with before/after scripts)
# or create a check to ensure that the command is only running a script from the $SOURCE_CLONE_URL
exec "$@"

# /bin/bash -c