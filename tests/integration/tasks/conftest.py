import os
import pytest
import logging
import shutil
import glob
import requests

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_generate_tests(metafunc):
    if "terra" in metafunc.fixturenames:
        metafunc.parametrize(
            "terra",
            [
                pytest.param(
                    {
                        "binary": "terragrunt",
                        "skip_teardown": True,
                        "env": {
                            "TF_VAR_approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
                            "TF_VAR_approval_request_sender_email": "fakesender@fake.com",
                            "TF_VAR_create_approval_sender_policy": "false",
                        },
                        "tfdir": f"{os.path.dirname(os.path.realpath(__file__))}/../../fixtures/terraform/mut/basic",
                    },
                )
            ],
            indirect=True,
            scope="session",
        )


def pytest_addoption(parser):
    group = parser.getgroup("Terra-Fixt")

    group.addoption(
        "--skip-tf-init",
        action="store_true",
        help="skips initing Terraform configuration",
    )

    group.addoption(
        "--skip-tf-apply",
        action="store_true",
        help="skips applying Terraform configuration",
    )

    group.addoption(
        "--preclean-terra",
        action="store_true",
        help="Destroys Terraform resources before any other subsequent terra* commands",
    )


@pytest.fixture(scope="session")
def mut(request, terra):
    if request.config.getoption("preclean_terra"):
        log.info("Destroying leftover Terraform resources before tests")
        if os.environ.get("IS_REMOTE", False):
            log.info("Running terraform destroy")
            terra.destroy(auto_approve=True)
        else:
            log.info("Removing .terra* and tfstate files")
            log.debug(f"Terra directory: {terra.tfdir}")

            path = os.path.join(terra.tfdir, ".terraform")

            if os.path.isdir(path):
                shutil.rmtree(path)
            path = os.path.join(terra.tfdir, "terraform.tfstate")

            if os.path.isfile(path):
                os.unlink(path)

            path = os.path.join(terra.tfdir, "**", ".terragrunt-cache*")
            for tg_dir in glob.glob(path, recursive=True):
                if os.path.isdir(tg_dir):
                    shutil.rmtree(tg_dir)

            log.info("Resetting moto server")
            requests.post(f"{os.environ['MOTO_ENDPOINT_URL']}/moto-api/reset")

    if not request.config.getoption("skip_tf_init"):
        terra.init()

    if not request.config.getoption("skip_tf_apply"):
        try:
            terra.apply(auto_approve=True)
        except Exception as e:
            log.error(e, exc_info=True)

    return terra
