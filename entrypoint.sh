#!/bin/bash
# shellcheck disable=SC1091
# SC1091: $VIRTUAL_ENV will is baked into testing docker image

if [ -n "$ADDITIONAL_PATH" ]; then
    echo "Adding to PATH: $ADDITIONAL_PATH"
    export PATH="$ADDITIONAL_PATH:$PATH"
fi

source "$VIRTUAL_ENV"/bin/activate
python3 -m pip install ".[all]"
python3 -m pip install -e /src

exec "$@"