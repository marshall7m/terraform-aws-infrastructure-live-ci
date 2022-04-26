ARG TERRAFORM_VERSION

FROM hashicorp/terraform:${TERRAFORM_VERSION}

COPY requirements.txt ./requirements.txt

ARG TERRAGRUNT_VERSION

RUN apk add --update --no-cache bash git \
    && python3 -m pip install --upgrade pip \
    && python3 -m pip install -r requirements.txt

ADD https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64 /usr/local/bin/terragrunt

RUN chmod +x /usr/local/bin/terragrunt

WORKDIR /src