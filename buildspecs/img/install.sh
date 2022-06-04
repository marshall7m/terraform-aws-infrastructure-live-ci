#!/bin/bash
python -m venv $VIRTUAL_ENV
source $VIRTUAL_ENV/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

wget -q -O /tmp/tfenv.tar.gz https://github.com/tfutils/tfenv/archive/refs/tags/v${TFENV_VERSION}.tar.gz
tar -zxf /tmp/tfenv.tar.gz -C /tmp
mkdir /usr/local/.tfenv && mv /tmp/tfenv-${TFENV_VERSION}/* /usr/local/.tfenv && chmod u+x /usr/local/.tfenv/bin/tfenv

wget -q -O /tmp/tgenv.tar.gz https://github.com/cunymatthieu/tgenv/archive/refs/tags/v${TGENV_VERSION}.tar.gz
tar -zxf /tmp/tgenv.tar.gz -C /tmp
mkdir /usr/local/.tgenv && mv /tmp/tgenv-${TGENV_VERSION}/* /usr/local/.tgenv && chmod u+x /usr/local/.tgenv/bin/tgenv

chmod u+x /usr/local/bin/*
rm -rf /tmp/*