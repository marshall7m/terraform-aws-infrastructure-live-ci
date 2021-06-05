import subprocess
import os
import re
import logging
log = logging.getLogger(__name__)


modified_dir = os.path.dirname(os.path.abspath(filepath))

os.chdir(modified_dir)

cmd = ['terragrunt', 'graph-dependencies', '--terragrunt-non-interactive']
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
dep_dirs = []
for line in proc.stdout.readlines():
    match = re.search('(?<=").+(?="\s;$)', line.decode('utf-8'))
    if match and match.group() != os.getcwd():
        dep_dirs.append(match.group())

dep_dirs.reverse()
print(dep_dirs)

target_paths = []
for path in dep_dirs:
    log.info(f'Path: {path}')

    run_plan = ['terragrunt', 'plan', '--terragrunt-working-dir', path, '-detailed-exitcode']
    err_code = subprocess.run(run_plan, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,).returncode

    log.debug(f'Error Code: {err_code}')
    if err_code == 0:
      log.info('No changes detected')
    elif err_code == 2:
      log.info('Changes detected')
      target_paths.append(path)
    else:
        log.error(f'Error running cmd: ${run_plan}')

target_paths.append(modified_dir)

print(target_paths)