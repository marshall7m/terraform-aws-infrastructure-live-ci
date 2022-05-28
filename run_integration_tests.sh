#!/bin/bash

source $VIRTUAL_ENV/bin/activate
python3 -m pip install -e .

pytest -vv tests/integration