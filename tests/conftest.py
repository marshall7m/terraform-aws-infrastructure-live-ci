import pytest
import os
import subprocess
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="session")
def tf_version():
    version = subprocess.run('terraform --version', shell=True, capture_output=True, text=True)
    if version.returncode == 0:
        log.info('Terraform found in $PATH -- skip scanning for tf version')
        log.info(f'Terraform Version: {version.stdout}')
    else:
        log.info('Scanning tf config for minimum tf version')
        out = subprocess.run('tfenv install min-required && tfenv use min-required', shell=True, capture_output=True, check=True, text=True
        )
        log.debug(f'tfenv out: {out.stdout}')

