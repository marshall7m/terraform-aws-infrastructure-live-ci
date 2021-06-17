import json
import logging

import github
import boto3
from github import Github
import os
import re
import ast
import collections.abc
import inspect
import operator
from typing import List, Union, Dict, Any
import tempfile
import subprocess


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
ssm = boto3.client('ssm')
sdb = boto3.client('sdb')
def lambda_handler(event, context):
    """

    Requirements:
        - Pre-existing SSM Paramter Store value for Github token. Parameter key must be specified under Lambda's env var: `GITHUB_TOKEN_SSM_KEY`
            (used to get filepaths that changed between head and base refs via PyGithub)
    """

    log = logging.getLogger(__name__)
	log.setLevel(logging.DEBUG)

    pr = sdb.select(SelectExpression=f"SELECT * FROM {os.environ['DOMAIN_NAME']}", )['Items']['Attributes']

    github_token = ssm.get_parameter(Name=os.environ['GITHUB_TOKEN_SSM_KEY'], WithDecryption=True)['Parameter']['Value']
    gh = Github(github_token)

    repo = gh.get_repo(os.environ['REPO_FULL_NAME'])
	#gets unique directories of files that changed between PR head commit and base commit
    modified_dirs = set([os.path.dirname(path.filename) for path in repo.compare(pr['BaseRef'], pr['HeadRef']).files])

    with tempfile.TemporaryDirectory() as tmpdirname:
        print('created temporary directory', tmpdirname)

        cmd = f"git clone {repo['clone_url']} -b {pr['HeadRef']} --single-branch".split('')
        proc = subprocess.run(cmd, capture_output=True, text=True).stdout
        
        dep_dict = get_run_order(modified_dirs)

    print(dep_dict)

def get_run_order(modified_dirs: list) -> Dict[str, List[str]]:
	"""
	Returns a map of the modified directory and its's associated Terragrunt depedency directories ordered by least immediate to most immediate depedency

	:param modified_dirs: List of directories that contain atleast Terragrunt *.hcl file
	"""
	log = logging.getLogger(__name__)
	log.setLevel(logging.DEBUG)

	deps_dict = {}
	all_deps = []	  
	for mod_dir in modified_dirs:
		if mod_dir not in all_deps:
			# gets terragrunt ordered dependencies of directory
			print(f'Modified Path: {mod_dir}')
			cmd = ['terragrunt', 'graph-dependencies', '--terragrunt-non-interactive', '--terragrunt-working-dir', mod_dir]
			proc = subprocess.run(cmd, capture_output=True, text=True).stdout
			#parses out directories within cmd output
			ordered_deps = re.findall('(?<=").+(?="\s;)', proc)
			log.debug(f'order dependencies: {ordered_deps}')
			dep_dirs = []
			for dep in ordered_deps:
				if is_modified(dep) and dep != mod_dir:
					dep_dirs.append(dep)
				if dep in modified_dirs:
					# skip runninng graph-deps on modified directory since directory and dependencies will be add within this iteration
					modified_dirs.remove(dep)


			# reverse dependency list to change order to least immediate to most immediate dependency
			dep_dirs.reverse()

			print(f'ordered deps: {dep_dirs}')

			deps_dict[mod_dir] = dep_dirs
		else:
			# skip runninng graph-deps given directory and associated deps are already within a higher-level modified dir
			continue

	log.debug(f'Modified directory and ordered dependencies: {deps_dict}')

	return deps_dict

def is_modified(dep):
	log.debug(f'Dependency path: {dep}')

	# run terragrunt plan to see if depedency cfg is different from tf state
	run_plan = ['terragrunt', 'plan', '--terragrunt-working-dir', dep, '-detailed-exitcode']
	out = subprocess.run(run_plan, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
	return_code = out.returncode

	log.debug(f'Return Code: {return_code}')

	if return_code == 0:
		log.info('No changes detected')
		return False
	elif return_code == 2:
		log.info('Changes detected')
		return True
	elif return_code == 1:
		log.info(f'Error running cmd: {" ".join(run_plan)}')
		log.debug('Checking if error is because of a depedency of a depedency has not been applied yet')
		
		# WA: Parse std error to see if dependency of dependency hasn't been applied is the cause
		# Use beter regex when terragrunt improves error formatting
		pattern = re.escape("but detected no outputs. Either the target module has not been applied yet, or the module has no outputs. If this is expected, set the skip_outputs flag to true on the dependency block")
		if re.search(pattern, out.stderr.decode('utf-8')):
			log.debug('Dependency of dependecy has not been applied. Returning True')
			return True