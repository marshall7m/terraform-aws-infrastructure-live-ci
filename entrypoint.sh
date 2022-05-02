#!/bin/bash

if [ -n "$ADDITIONAL_PATH" ]; then
    echo "Adding to PATH: $ADDITIONAL_PATH"
    export PATH="$ADDITIONAL_PATH:$PATH"
fi

source $VIRTUAL_ENV/bin/activate

pip install -e /src

/bin/bash