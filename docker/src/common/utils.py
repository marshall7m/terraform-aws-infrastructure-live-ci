import logging
import subprocess

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TerragruntException(Exception):
    """Wraps around Terragrunt-related errors"""

    pass


class ClientException(Exception):
    """Wraps around client-related errors"""

    pass


def subprocess_run(cmd: str, check=True):
    """subprocess.run() wrapper that logs the stdout and raises a subprocess.CalledProcessError exception and logs the stderr if the command fails
    Arguments:
        cmd: Command to run
    """
    log.debug(f"Command: {cmd}")
    try:
        run = subprocess.run(
            cmd.split(" "), capture_output=True, text=True, check=check
        )
        log.debug(f"Stdout:\n{run.stdout}")
        return run
    except subprocess.CalledProcessError as e:
        log.error(e.stderr)
        raise e
