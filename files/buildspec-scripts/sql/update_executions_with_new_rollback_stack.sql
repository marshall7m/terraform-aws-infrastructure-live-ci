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

CREATE OR REPLACE FUNCTION pg_temp.insert_rollback_stack(_commit_id VARCHAR)
    RETURNS SETOF executions AS $$
    BEGIN 
        RAISE NOTICE '_commit_id: %', _commit_id;

        RETURN QUERY EXECUTE format('INSERT INTO executions (
            execution_id,
            is_rollback,
            pr_id,
            commit_id,
            base_ref,
            head_ref,
            base_source_version,
            head_source_version,
            cfg_path,
            cfg_deps,
            "status",
            plan_command,
            deploy_command,
            new_providers,
            new_resources,
            account_name,
            account_path,
            account_deps,
            voters,
            approval_count,
            min_approval_count,
            rejection_count,
            min_rejection_count
        )
        SELECT
            ''run-'' || substr(md5(random()::text), 0, 8) as execution_id,
            true as is_rollback,
            pr_id,
            commit_id,
            base_ref,
            head_ref,
            base_source_version,
            head_source_version,
            cfg_path,
            cfg_deps,
            ''waiting'' as status,
            ''terragrunt destroy'' || target_resources(new_resources) as plan_command,
            ''terragrunt destroy'' || target_resources(new_resources) || '' -auto-approve'' as deploy_commmand,
            new_providers,
            new_resources,
            account_name,
            account_path,
            account_deps,
            voters,
            0 as approval_count,
            min_approval_count,
            0 as rejection_count,
            min_rejection_count
        FROM
            executions
        WHERE
            commit_id = %s AND
            cardinality(new_resources) > 0
        RETURNING executions.*;', _commit_id);
    END;
$$ LANGUAGE plpgsql;

SELECT * FROM pg_temp.insert_rollback_stack(:'commit_id');