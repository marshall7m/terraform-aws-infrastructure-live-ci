import subprocess
import logging
import sys

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

def subprocess_run(cmd: str, check=True):
    '''subprocess.run() wrapper that logs the stdout and raises a subprocess.CalledProcessError exception and logs the stderr if the command fails
    Arguments:
        cmd: Command to run
    '''
    log.debug(f'Command: {cmd}')
    try:
        run = subprocess.run(cmd.split(' '), capture_output=True, text=True, check=check)
        log.debug(f'Stdout:\n{run.stdout}')
        return run
    except subprocess.CalledProcessError as e:
        log.error(e.stderr)
        raise e