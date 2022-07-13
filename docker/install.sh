#!/bin/bash
# shellcheck disable=SC1091
# SC1091: $VIRTUAL_ENV will be exported from the Dockerfile

set -e

apt-get -y update
apt-get install -y wget

python -m venv "$VIRTUAL_ENV"
source "$VIRTUAL_ENV"/bin/activate
python3 -m pip install --upgrade -r requirements.txt

wget -q -O /tmp/tfenv.tar.gz https://github.com/tfutils/tfenv/archive/refs/tags/v"${TFENV_VERSION}".tar.gz
tar -zxf /tmp/tfenv.tar.gz -C /tmp
mkdir /usr/local/.tfenv && mv /tmp/tfenv-"${TFENV_VERSION}"/* /usr/local/.tfenv && chmod u+x /usr/local/.tfenv/bin/tfenv

wget -q -O - https://raw.githubusercontent.com/warrensbox/tgswitch/release/install.sh | bash -s -- -b /usr/local/bin -d "${TGSWITCH_VERSION}"

chmod u+x /usr/local/bin/*
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*