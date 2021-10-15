CREATE OR REPLACE FUNCTION pg_temp.insert_deploy_stack(_account_path VARCHAR, _commit_id VARCHAR, _base_commit_id VARCHAR)
    RETURNS SETOF executions AS $$
    BEGIN 
        RAISE NOTICE '_account_path: %', _account_path;
        RAISE NOTICE '_commit_id: %', _commit_id;
        RAISE NOTICE '_base_commit_id: %', _base_commit_id;

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
            ''run-'' || substr(md5(random()::text), 0, 8),
            false,
            "commit".pr_id,
            "commit".commit_id,
            "commit".base_ref,
            "commit".head_ref,
            ''refs/heads/'' || "commit".base_ref || ''^{'' || %s || ''}'',
            ''refs/pull/'' || "commit".pr_id || ''/head^{'' || "commit".commit_id || ''}'',
            stack.cfg_path,
            stack.cfg_deps,
            ''waiting'',
            -- TODO: add user defined extra tf args from terraform module input
            ''terragrunt plan --terragrunt-working-dir '' || stack.cfg_path,
            ''terragrunt apply --terragrunt-working-dir '' || stack.cfg_path || '' -auto-approve'',
            stack.new_providers, 
            ARRAY[]::TEXT[],
            account.account_name,
            account.account_path,
            account.account_deps,
            account.voters,
            0,
            account.min_approval_count,
            0,
            account.min_rejection_count
        FROM (
            SELECT
                pr_queue.pr_id,
                base_ref,
                head_ref,
                commit_id
            FROM commit_queue
            JOIN pr_queue
            ON pr_queue.pr_id = commit_queue.pr_id
            WHERE commit_queue.commit_id = %s
        ) "commit",
        (
            SELECT
                account_dim.account_name,
                account_dim.account_path,
                account_dim.account_deps,
                account_dim.voters,
                account_dim.min_approval_count,
                account_dim.min_rejection_count
            FROM account_dim
            WHERE account_dim.account_path = %s
        ) account,
        (
            SELECT *
            FROM staging_cfg_stack
        ) stack
        RETURNING executions.*;', _base_commit_id, _commit_id, _account_path);
    END;
$$ LANGUAGE plpgsql;

SELECT * FROM pg_temp.insert_deploy_stack(:'account_path', :'commit_id', :'base_commit_id');