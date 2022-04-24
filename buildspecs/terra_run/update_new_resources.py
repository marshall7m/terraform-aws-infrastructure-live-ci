import os
import subprocess
import logging
import json
import aurora_data_api

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def get_new_provider_resources(tg_dir, new_providers):
    cmd = f'terragrunt state pull --terragrunt-working-dir {tg_dir}'
    log.debug(f'Running command: {cmd}')
    run = subprocess.run(cmd.split(' '), capture_output=True, text=True, check=True)
    log.debug(f'Stdout:\n{run.stdout}')
    if not run.stdout:
        return []
    
    return [resource['type'] + '.' + resource['name'] for resource in json.loads(run.stdout)['resources'] if resource['provider'].split('\"')[1] in new_providers]

def main():

    if os.environ.get('NEW_PROVIDERS', False) != '[]' and os.environ['IS_ROLLBACK'] == 'false':

        log.info('Switching back to CodeBuild base IAM role')
        log.info('Adding new provider resources to associated execution record')
        new_providers = os.environ['NEW_PROVIDERS'].split(', ')
        resources = get_new_provider_resources(os.environ['CFG_PATH'], new_providers)
        if len(resources) > 0:
            with aurora_data_api.connect(
                aurora_cluster_arn=os.environ['METADB_CLUSTER_ARN'],
                secret_arn=os.environ['METADB_SECRET_ARN'],
                database=os.environ['METADB_NAME']
            ) as conn:
                with conn.cursor() as cur:
                    resources = ','.join(resources)
                    cur.execute(f"""
                    UPDATE executions 
                    SET new_resources = string_to_array('{resources}', ',') 
                    WHERE execution_id = '{os.environ["EXECUTION_ID"]}'
                    RETURNING new_resources
                    """)

                    log.debug(cur.fetchone())
        else:
            log.info('New provider resources were not created -- skipping')
    else:
        log.info('New provider resources were not created -- skipping')

if __name__ == '__main__':
    main()