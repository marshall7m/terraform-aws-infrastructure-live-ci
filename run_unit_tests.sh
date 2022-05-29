#!/bin/bash

source $VIRTUAL_ENV/bin/activate
python3 -m pip install -r requirements.txt
python3 -m pip install -e /src

apt-get -y update
apt-get -y make g++ automake subversion cmake yarn musl-dev linux-headers \
libffi-dev libxml2 libxml2-dev gcc libxslt-dev postgresql-dev postgresql-client

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

pytest -vv tests/unit