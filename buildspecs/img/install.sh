#!/bin/bash
# shellcheck disable=SC1091
# SC1091: $VIRTUAL_ENV will be exported from the Dockerfile

python -m venv "$VIRTUAL_ENV"
source "$VIRTUAL_ENV"/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

wget -q -O /tmp/tfenv.tar.gz https://github.com/tfutils/tfenv/archive/refs/tags/v"${TFENV_VERSION}".tar.gz
tar -zxf /tmp/tfenv.tar.gz -C /tmp
mkdir /usr/local/.tfenv && mv /tmp/tfenv-"${TFENV_VERSION}"/* /usr/local/.tfenv && chmod u+x /usr/local/.tfenv/bin/tfenv

curl -L https://raw.githubusercontent.com/warrensbox/tgswitch/release/install.sh | bash -s -- -b /usr/local/bin -d "${TGSWITCH_VERSION}"

chmod u+x /usr/local/bin/*
rm -rf /tmp/*