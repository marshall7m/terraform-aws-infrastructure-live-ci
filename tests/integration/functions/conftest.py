import pytest


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """Adds an request method to determine if any of the test failed within conftest scope"""
    outcome = yield
    res = outcome.get_result()
    if res.outcome == "failed":
        item.module.any_failures = True


def pytest_generate_tests(metafunc):
    # creates a dummy remote repo based on specified template repo
    if "repo" in metafunc.fixturenames:
        metafunc.parametrize(
            "repo",
            ["marshall7m/infrastructure-live-testing-template"],
            scope="module",
            indirect=True,
        )
