import os
import logging

import tftest

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

FILE_DIR = os.path.dirname(__file__)


def test_plan(request):
    """
    Ensure that the Terraform module produces a valid Terraform plan with just
    the module's required variables defined
    """
    cache_dir = str(request.config.cache.makedir("tftest"))
    log.info(f"Caching Tftest results to {cache_dir}")

    tf = tftest.TerragruntTest(
        tfdir=os.path.join(FILE_DIR, "../../fixtures/terraform/mut/defaults"),
        enable_cache=False,
        cache_dir=cache_dir,
        env={"IS_REMOTE": "False"},
    )

    tf.setup(cleanup_on_exit=True)
    tf.plan(output=True)
