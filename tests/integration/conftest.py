import pytest
import requests
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def pytest_addoption(parser):
    parser.addoption(
        "--skip-moto-reset", action="store_true", help="skips resetting moto server"
    )
@pytest.fixture(scope="session")
def reset_moto_server(request):
    yield None
    skip = request.config.getoption("skip_moto_reset")
    if skip:
        log.info("Skip resetting moto server")
    else:
        log.info("Resetting moto server")
        requests.post("http://localhost:5000/moto-api/reset")