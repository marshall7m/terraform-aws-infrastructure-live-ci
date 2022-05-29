#!/bin/bash

if [ -n "$ADDITIONAL_PATH" ]; then
    echo "Adding to PATH: $ADDITIONAL_PATH"
    export PATH="$ADDITIONAL_PATH:$PATH"
fi

source $VIRTUAL_ENV/bin/activate
python3 -m pip install -r requirements.txt
python3 -m pip install -e /src

exec "$@"