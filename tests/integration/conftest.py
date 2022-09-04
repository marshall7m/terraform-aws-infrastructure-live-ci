import pytest
import requests
import os
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_addoption(parser):
    parser.addoption(
        "--skip-moto-reset", action="store_true", help="skips resetting moto server"
    )


def pytest_generate_tests(metafunc):
    tf_versions = [pytest.param("latest")]
    if "terraform_version" in metafunc.fixturenames:
        tf_versions = [pytest.param("latest")]
        metafunc.parametrize(
            "terraform_version",
            tf_versions,
            indirect=True,
            scope="session",
            ids=[f"tf_{v.values[0]}" for v in tf_versions],
        )

    if "tf" in metafunc.fixturenames:
        metafunc.parametrize(
            "tf",
            [f"{os.path.dirname(__file__)}/fixtures"],
            indirect=True,
            scope="session",
        )


@pytest.fixture(scope="session")
def reset_moto_server(request):
    yield None
    skip = request.config.getoption("skip_moto_reset")
    if skip:
        log.info("Skip resetting moto server")
    else:
        log.info("Resetting moto server")
        requests.post(f"{os.environ['MOTO_ENDPOINT_URL']}/moto-api/reset")
