#!/bin/bash
apk update
apk add --no-cache --virtual .build-deps libffi-dev make musl-dev gcc postgresql-dev 
python -m venv $VIRTUAL_ENV
source $VIRTUAL_ENV/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

wget -q -O /tmp/terraform.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
unzip -q /tmp/terraform.zip
mv $(unzip -qql /tmp/terraform.zip | head -n1 | tr -s ' ' | cut -d' ' -f5-) /usr/local/bin/
wget -q -O /usr/local/bin/terragrunt https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64

chmod u+x /usr/local/bin/*

apk del .build-deps
rm -rf /tmp/*
rm -rf /var/cache/apk/*