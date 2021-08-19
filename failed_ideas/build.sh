pr_id=1
head_ref=
git fetch origin pull/$pr_id/head:$head_ref
git checkout $head_ref

deps=$(python <<HEREDOC
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
import argparse


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def get_run_order(modified_dirs: list) -> Dict[str, List[str]]:
	"""
	Returns a map of the modified directory and its's associated Terragrunt depedency directories ordered by least immediate to most immediate depedency

	:param modified_dirs: List of directories that contain Terragrunt *.hcl files
	"""
	log = logging.getLogger(__name__)
	log.setLevel(logging.DEBUG)

	deps_dict = {}
	all_deps = []	  
	for mod_dir in modified_dirs:
		if mod_dir not in all_deps:
			# gets terragrunt ordered dependencies of directory
			log.debug(f'Modified Path: {mod_dir}')
			cmd = ['terragrunt', 'graph-dependencies', '--terragrunt-non-interactive', '--terragrunt-working-dir', mod_dir]
			proc = subprocess.run(cmd, capture_output=True, text=True).stdout
			#parses out directories within cmd output
			ordered_deps = re.findall('(?<=").+(?="\s;)', proc)
			log.debug(f'order dependencies: {ordered_deps}')
			dep_dirs = []
			for dep in ordered_deps:
				if dep != mod_dir:
					dep_dirs.append(dep)
				if dep in modified_dirs:
					# skip runninng graph-deps on modified directory since directory and dependencies will be add within this iteration
					modified_dirs.remove(dep)

			# reverse dependency list to change order to least immediate to most immediate dependency
			dep_dirs.reverse()

			log.debug(f'ordered deps: {dep_dirs}')

			deps_dict[mod_dir] = dep_dirs
		else:
			# skip runninng graph-deps given directory and associated deps are already within a higher-level modified dir
			continue

	log.debug(f'Modified directory and ordered dependencies: {deps_dict}')

	return deps_dict

cmd = "terragrunt run-all plan --terragrunt-non-interactive --terragrunt-log-level error -detailed-exitcode".split(" ")
out = subprocess.run(cmd, text=True, capture_output=True)
diff_paths = re.findall("(?<=exit\sstatus\s2\sprefix=\[).+(?=\])", out.stderr)

diff_run_order = get_run_order(diff_paths)

response = client.start_execution(
    stateMachineArn=os.environ['STEP_MACHINE_ARN'],
    input=f'input: {"diff_run_order": json.dumps(diff_run_order)}',
)
print()

HEREDOC)