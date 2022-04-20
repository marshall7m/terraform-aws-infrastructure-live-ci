#!/bin/bash
apk update
apk add --no-cache --virtual .build-deps \
    make g++ automake subversion cmake yarn musl-dev linux-headers \
    libffi-dev libxml2 libxml2-dev gcc libxslt-dev postgresql-dev python3-dev

yarn install

python -m venv $VIRTUAL_ENV
source $VIRTUAL_ENV/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

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
wget -q -O /tmp/gh.tar.gz https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz
tar -zxf /tmp/gh.tar.gz -C /tmp
mv /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/
wget -q -O /tmp/tfenv.tar.gz https://github.com/tfutils/tfenv/archive/refs/tags/v${TFENV_VERSION}.tar.gz
tar -zxf /tmp/tfenv.tar.gz -C /tmp
mkdir /usr/local/.tfenv && mv /tmp/tfenv-${TFENV_VERSION}/* /usr/local/.tfenv && chmod u+x /usr/local/.tfenv/bin/tfenv
wget -q -O /tmp/tgswitch.tar.gz https://github.com/warrensbox/tgswitch/releases/download/${TGSWITCH_VERSION}/tgswitch_${TGSWITCH_VERSION}_linux_arm64.tar.gz
tar -zxf /tmp/tgswitch.tar.gz -C /tmp
mv /tmp/tgswitch /usr/local/bin/

chmod u+x /usr/local/bin/*
apk del .build-deps
rm -rf /tmp/*
rm -rf /var/cache/apk/*