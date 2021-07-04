#!/bin/bash

apt-get update
apt-get install -y $BUILD_PACKAGES --no-install-recommends 
pip install --upgrade pip --upgrade --no-cache-dir -r requirements.txt
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
chmod u+x /usr/local/bin/*
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*