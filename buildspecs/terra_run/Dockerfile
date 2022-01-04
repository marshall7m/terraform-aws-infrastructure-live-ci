FROM hashicorp/terraform:TERRAFORM_VERSION

ARG TERRAGRUNT_VERSION

RUN apk add --update --no-cache bash git openssh

ADD https://github.com/gruntwork-io/terragrunt/releases/download/${TERRAGRUNT_VERSION}/terragrunt_linux_amd64 /usr/local/bin/terragrunt

RUN chmod +x /usr/local/bin/terragrunt

WORKDIR /src