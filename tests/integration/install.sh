#!/bin/bash

apk add --no-cache --virtual .build-deps yarn wget unzip python3 py-pip python3-dev musl-dev linux-headers libxml2 libxml2-dev gcc libxslt-dev

python3 -m venv $VIRTUAL_ENV
source $VIRTUAL_ENV/bin/activate
pip3 install --upgrade pip
pip3 install --no-cache-dir -r requirements.txt

wget -q -O /tmp/tfenv.zip https://github.com/tfutils/tfenv/archive/refs/tags/v${TFENV_VERSION}.zip
unzip -q /tmp/tfenv.zip -d /usr/local/.tfenv
export PATH=$PATH:/usr/local/.tfenv/tf-env-${TFENV_VERSION}/bin
wget -q -O /tmp/terraform.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
unzip -q /tmp/terraform.zip
mv $(unzip -qql /tmp/terraform.zip | head -n1 | tr -s ' ' | cut -d' ' -f5-) /usr/local/bin/
wget -q -O /usr/local/bin/terragrunt https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64
wget -q -O /tmp/tflint.zip https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip
unzip -q /tmp/tflint.zip
mv $(unzip -qql /tmp/tflint.zip | head -n1 | tr -s ' ' | cut -d' ' -f5-) /usr/local/bin/
wget -q -O /usr/local/bin/tfsec https://github.com/tfsec/tfsec/releases/download/v${TFSEC_VERSION}/tfsec-linux-amd64
wget -q -O /usr/local/bin/terraform-docs https://github.com/terraform-docs/terraform-docs/releases/download/v${TFDOCS_VERSION}/terraform-docs-v${TFDOCS_VERSION}-linux-amd64
wget -q -O /tmp/git-chglog.tar.gz https://github.com/git-chglog/git-chglog/releases/download/v${GIT_CHGLOG_VERSION}/git-chglog_${GIT_CHGLOG_VERSION}_linux_amd64.tar.gz
tar -zxf /tmp/git-chglog.tar.gz -C /tmp
mv /tmp/git-chglog /usr/local/bin/
wget -q -O /tmp/semtag.tar.gz https://github.com/nico2sh/semtag/archive/refs/tags/v${SEMTAG_VERSION}.tar.gz
tar -zxf /tmp/semtag.tar.gz -C /tmp
mv /tmp/semtag-${SEMTAG_VERSION}/semtag /usr/local/bin/
wget -q -O /tmp/gh.tar.gz https://github.com/cli/cli/releases/download/v2.2.0/gh_2.2.0_linux_amd64.tar.gz
tar -zxf /tmp/gh.tar.gz -C /tmp
mv /tmp/gh /usr/local/bin

chmod u+x /usr/local/bin/*

apk del .build-deps
rm -rf /tmp/*
rm -rf /var/cache/apk/*