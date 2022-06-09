#!/bin/bash
# shellcheck disable=SC1091
# SC1091: $VIRTUAL_ENV will is baked into testing docker image

if [ -n "$ADDITIONAL_PATH" ]; then
    echo "Adding to PATH: $ADDITIONAL_PATH"
    export PATH="$ADDITIONAL_PATH:$PATH"
fi

scversion="stable"
echo "Installing shellcheck - ${scversion}"

apt-get install -y xz-utils
curl -L -s -o /tmp/shellcheck-${scversion?}.linux.x86_64.tar.xz https://github.com/koalaman/shellcheck/releases/download/${scversion?}/shellcheck-${scversion?}.linux.x86_64.tar.xz
tar -xf /tmp/shellcheck-${scversion?}.linux.x86_64.tar.xz -C /tmp
cp "/tmp/shellcheck-${scversion}/shellcheck" /usr/local/bin/
shellcheck --version

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

source "$VIRTUAL_ENV"/bin/activate
python3 -m pip install -r requirements.txt
python3 -m pip install -e /src

exec "$@"