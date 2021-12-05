import psycopg2
import pytest
import mock
import os
import logging
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL
import pandas.io.sql as psql
from helpers.utils import TestSetup

import uuid
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="function", autouse=True)
def codebuild_env():
    os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
    os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'
    os.environ['BASE_REF'] = 'master'
    os.environ['AWS_DEFAULT_REGION'] = 'us-west-2'
    os.environ['STATE_MACHINE_ARN'] = 'mock-sf-arn'

    os.environ['PGOPTIONS'] = '-c statement_timeout=100000'

# mock step function client
@mock.patch('buildspecs.trigger_sf.sf')
@pytest.mark.parametrize("scenario", [
    ("scenario_1"),
    ("scenario_2"),
    ("scenario_3")
])
def test_record_exists(mock_aws, scenario, function_repo_dir, request):
    log.debug(f"Scenario: {scenario}")
    scenario = request.getfixturevalue(scenario)

    os.chdir(function_repo_dir)

    log.debug(f'CWD: {os.getcwd()}')

    #TODO: Figure out how to put trigger.main() within fixture thats dependent on scenario and calls .cleanup() yielding .main()
    trigger = TriggerSF()
    try:
        trigger.main()
    finally:
        trigger.cleanup()

    log.info("Running record assertions:")
    with psycopg2.connect() as conn:     
        scenario.run_collected_assertions(conn)