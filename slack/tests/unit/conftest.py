import pytest
from pyngrok import ngrok
from slack import approval_response
from werkzeug.wrappers import Request, Response
from slack_sdk.web import WebClient
import os
import yaml
import json
import uuid
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

with open(f"{os.path.dirname(__file__)}/../../app_manifest.yml") as f:
    manifest = yaml.safe_load(f)

@pytest.fixture(scope="session")
def httpserver_listen_address():
    return ("localhost", 8888)


@pytest.fixture(scope="session")
def ngrok_tunnel(httpserver_listen_address):
    log.info("Creating ngrok tunnel")
    tunnel = ngrok.connect(httpserver_listen_address[1], "http")
    
    yield tunnel

    log.info("Closing ngrok tunnel")
    ngrok.disconnect(tunnel.public_url)    


@pytest.fixture(scope="session")
def slack_channel():
    slack_client = WebClient(token=os.environ["SLACK_BOT_TOKEN"])

    log.info("Creating channel")
    channel = slack_client.conversations_create(name=f"test-approval-{uuid.uuid4()}")["channel"]

    yield channel

    log.info('Closing channel')
    slack_client.conversations_close(channel=channel["id"])


def accept_challenge(request):
    return Response(request.json["challenge"])


@pytest.fixture(scope="session")
def slack_app(ngrok_tunnel, make_httpserver):

    make_httpserver.expect_request("/").respond_with_handler(accept_challenge)

    log.info("Creating Slack app")
    app_client = WebClient(token=os.environ["SLACK_APP_TOKEN"])

    manifest["settings"]["interactivity"]["request_url"] = ngrok_tunnel.public_url
    # WA: using client.api_call() until client.apps_manifest_*() is supported within official release
    # related PR: https://github.com/slackapi/python-slack-sdk/pull/1123
    
    # WA: since Slack API doesn't support integrating app into workspace,
    # 
    app = app_client.api_call(
        "apps.manifest.update",
        params={
            "manifest": json.dumps(manifest)
        }
    )
    log.debug(f"APP: {app}")
    app["oauth_authorize_url"] + "&user_scope=&redirect_uri=&state=&granular_bot_scope=1&single_channel=0&install_redirect=install-on-team&tracked=1&team=1"

    yield app

    log.info("Deleting Slack app")
    app_client.api_call(
        "apps.manifest.delete",
        params={
            "app_id": app["app_id"]
        }
    )


@pytest.fixture
def approval_request(slack_app, slack_channel):
    return ApprovalRequest(
        slack_channel["id"],
        manifest["features"]["bot_user"]["display_name"],
        "run-123",
        "dev/foo"
    )