import os
import logging
import uuid
import json

import pytest
import github

from tests.helpers.utils import push

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture
def push_changes(mut_output, request):
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"], retry=3)
    branch = f"test-{uuid.uuid4()}"
    repo = gh.get_repo(mut_output["repo_full_name"])

    yield {
        "commit_id": push(repo, branch, request.param),
        "branch": branch,
        "changes": request.param,
    }

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()


@pytest.fixture
def mock_sf_cfg(mut_output):
    """
    Overwrites Step Function State Machine placeholder name with name from Terraform module.
    See here for more info on mock config file:
    https://docs.aws.amazon.com/step-functions/latest/dg/sfn-local-mock-cfg-file.html
    """
    log.info(
        "Replacing placholder state machine name with: "
        + mut_output["step_function_name"]
    )
    mock_path = os.path.join(os.path.dirname(__file__), "mock_sf_cfg.json")
    with open(mock_path, "r") as f:
        cfg = json.load(f)

    cfg["StateMachines"][mut_output["step_function_name"]] = cfg["StateMachines"].pop(
        "Placeholder"
    )

    with open(mock_path, "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)

    yield mock_path

    log.info("Replacing state machine name back with placholder")
    with open(mock_path, "r") as f:
        cfg = json.load(f)

    cfg["StateMachines"]["Placeholder"] = cfg["StateMachines"].pop(
        mut_output["step_function_name"]
    )

    with open(mock_path, "w") as f:
        json.dump(cfg, f, indent=4, sort_keys=True)
