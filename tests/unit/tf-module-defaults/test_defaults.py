import os
import logging
import tftest
import pytest
import sys

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

def test_defaults():
    tf_dir = os.path.dirname(os.path.realpath(__file__))

    if 'GITHUB_TOKEN' not in os.environ:
        pytest.fail('$GITHUB_TOKEN env var is not set -- required to setup Github resources')

    tf = tftest.TerraformTest(tf_dir)

    log.info('Initializing testing module')
    tf.init()

    log.info('Getting testing tf plan')
    out = tf.plan(output=True)
    log.debug(out)