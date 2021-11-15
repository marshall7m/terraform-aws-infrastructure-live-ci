git_root=$(git rev-parse --show-toplevel)

docker run -it -v "$git_root":/src -e "$AWS_ACCESS_KEY_ID" -e "$AWS_SECRET_ACCESS_KEY" -e "$AWS_REGION" -e "$AWS_SESSION_TOKEN" \
    terraform-aws-infrastructure-live-ci-integration-testing:latest \
    /bin/bash
    # terragrunt test