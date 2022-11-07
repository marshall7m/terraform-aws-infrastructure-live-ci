import pytest


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """Adds an request method to determine if any of the test failed within conftest scope"""
    outcome = yield
    res = outcome.get_result()
    if res.outcome == "failed":
        item.module.any_failures = True
