#!/bin/bash

export PATH="$ADDITIONAL_PATH:$PATH"
/bin/bash

source $VIRTUAL_ENV/bin/activate
pip install -e .