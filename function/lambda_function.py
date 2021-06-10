import json
import logging
import boto3
from github import Github
import os
import re
import ast
import collections.abc
import inspect
import operator
from typing import List, Union, Dict, Any


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
ssm = boto3.client('ssm')
cp = boto3.client('codepipeline')

def lambda_handler(event, context):
    """
    Checks if a Github payload passes atleast one of the filter groups
    and if it passes, runs the associated Codepipeline with updated stage actions.

    Requirements:
        - Lambda Function must be invoked asynchronously
        - Payload body must be mapped to the key `body`
        - Payload headers must be mapped to the key `headers`
        - SSM Paramter Store value for Codebuild project name : Parameter key must be specified under Lambda's env var: `CODEBUILD_NAME`
        - Pre-existing SSM Paramter Store value for Github token. Parameter key must be specified under Lambda's env var: `GITHUB_TOKEN_SSM_KEY`
            (used to get filepaths that changed between head and base refs via PyGithub)
        - Filter groups, filter events, and CodeBuild override params must be specified in /opt/repo_cfg.json
    """

    payload = json.loads(event['requestPayload']['body'])
    event = event['requestPayload']['headers']['X-GitHub-Event']
    repo_name = payload['repository']['name']

    generate_stages(event, payload)

    #run SF with generated stages as input

def generate_stages(event, payload):
    if event == "pull_request" and payload['action'] != 'closed':
        modified_dirs = 

    run_dict = get_run_order(modified_dirs)
class ClientException(Exception):
    """Wraps around client-related errors"""
    pass


