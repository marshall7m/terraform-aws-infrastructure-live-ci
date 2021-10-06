CREATE OR REPLACE FUNCTION target_resources(text[]) RETURNS text AS $$
    DECLARE
        flags text := '';
        resource text;
    BEGIN
        FOREACH resource IN ARRAY $1
        LOOP
            flags := flags || ' -target ' || resource;
        END LOOP;
        RETURN flags;
    END;
$$ LANGUAGE plpgsql;

INSERT INTO
    executions
SELECT
    'run-' || substr(md5(random()::text), 0, 8) as execution_id,
    true as is_rollback,
    pr_id,
    commit_id,
    base_source_version,
    head_source_version,
    cfg_path,
    cfg_deps,
    'waiting' as status,
    'terragrunt destroy' || target_resources(new_resources) as plan_command,
    'terragrunt destroy' || target_resources(new_resources) || ' -auto-approve' as deploy_commmand,
    new_providers,
    new_resources,
    account_name,
    account_deps,
    account_path,
    voters,
    0 as approval_count,
    min_approval_count,
    0 as rejection_count,
    min_rejection_count
FROM
    executions
WHERE
    commit_id = :'commit_id' AND
    cardinality(new_resources) > 0