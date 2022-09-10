#!/bin/bash
# shellcheck disable=SC1091
# SC1091: $VIRTUAL_ENV will is baked into testing docker image
export AWS_DEFAULT_REGION="$AWS_REGION"

if [ -n "$ADDITIONAL_PATH" ]; then
    echo "Adding to PATH: $ADDITIONAL_PATH"
    export PATH="$ADDITIONAL_PATH:$PATH"
fi

if [ -n "$ADDITIONAL_PYTHONPATH" ]; then
    echo "Adding to PYTHONPATH: $ADDITIONAL_PYTHONPATH"
    export PYTHONPATH="$ADDITIONAL_PYTHONPATH:$PYTHONPATH"
fi


source "$VIRTUAL_ENV"/bin/activate
python3 -m pip install -e /src

exec "$@"