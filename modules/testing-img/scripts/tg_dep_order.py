import json
import logging

import boto3
import os
import re
from typing import List, Union, Dict, Any
import subprocess
import argparse
from time import process_time

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TerragruntError(Exception):
    """Raised Terragrunt CLI command fails"""
    pass

def get_run_order(modified_dirs: list) -> Dict[str, List[str]]:
    """
    Returns a map of the modified directory and its's associated Terragrunt depedency directories ordered by least immediate to most immediate depedency

    :param modified_dirs: List of directories that contain Terragrunt *.hcl files
    """
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    targets = []
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
            run_order = []
            for dep in ordered_deps:
                run_order.append(dep)
                if dep in modified_dirs:
                    # skip runninng graph-deps on modified directory since directory and dependencies will be add within this iteration
                    modified_dirs.remove(dep)

            # reverse dependency list to change order to least immediate to most immediate dependency
            run_order.reverse()
            log.debug(f'run order: {run_order}')

            targets.append(run_order)
        else:
            # skip runninng graph-deps given directory and associated deps are already within a higher-level modified dir
            continue

    log.debug(f'Modified directory and ordered dependencies: {targets}')

    return targets

def get_order(parsed_stack):
    
    module_list = list(parsed_stack.keys())

    run_order = {}
    for key in module_list:
        for module, dep_list in parsed_stack.items():
            if key in dep_list:
                run_order[module] = parsed_stack[key] + parsed_stack[module]
                run_order.pop(key, None)
                
                log.debug('Updated run order:')
                log.debug(run_order)

    # put into list of list for step function map to loop over
    run_order = [ value + [key] for key, value in run_order.items() ]
    return run_order

def get_diff_stack(parent):
    cmd = ['terragrunt', 'run-all', 'plan', '--terragrunt-working-dir', parent, '--terragrunt-non-interactive', '-detailed-exitcode']
    
    log.info('Running Terragrunt command:')
    log.info(''.join(cmd))

    out = subprocess.run(cmd, text=True, capture_output=True)
    
    if out.returncode == 1:
        err = out.stderr
        log.error('Terragrunt command resulted in error')
        raise TerragruntError(err)

    diff_paths = re.findall("(?<=exit\sstatus\s2\sprefix=\[).+(?=\])", out.stderr)
    
    print('diff paths')
    print(diff_paths)
    print()

    stack_paths = re.findall("(?<=\s\s=>\sModule\s).+(?=\n)", out.stderr)

    parsed_stack = {}
    for stack in stack_paths:
        # TODO: Figure out more stable regex patterns
        module = re.findall('.+(?=\s\(excluded)', stack)[0]
        # TODO: Remove horrible workaround for regex incompetence 
        deps = [dir_path for match in re.findall("(?<=\[).+(?=\])", stack) for dir_path in match.replace(' ', '').split(',')]
        parsed_stack[module] = deps

    diff_stack = { key: value for key, value in parsed_stack.items() if key in diff_paths }

    return diff_stack

if __name__ == '__main__':
    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)
    
    parser = argparse.ArgumentParser(description='Parses Terragrunt directory depedencies')
    parser.add_argument('--parent', type=str, default=os.getcwd(),
                        help='Parent Terragrunt directory. Limits the scope of directories to be scanned for dependencies')
    parser.add_argument('--machine-arn', type=str, default=None,
                        help='Step function ARN to invoke')

    args = parser.parse_args()
    log.info(f'Arguments: {vars(args)}')

    diff_stack = get_diff_stack(args.parent)
    print('diff stack')
    print(diff_stack)
    run_order = get_order(diff_stack)

    print()
    print(run_order)

    if args.machine_arn:
        sf = boto3.client('stepfunctions')

        sf_input = f'"input": {json.dumps(run_order)}'
        
        log.info(f'Invoking Step Function Machine: {args.machine_arn}')
        log.info(f'Step Function Input: {sf_input}')
        response = sf.start_execution(
            stateMachineArn=args.machine_arn,
            input=sf_input
        )
