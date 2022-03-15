CREATE OR REPLACE FUNCTION target_resources(TEXT[]) RETURNS text AS $$
    DECLARE
        flags TEXT := '';
        "resource" TEXT;
    BEGIN
        FOREACH "resource" IN ARRAY $1
        LOOP
            flags := flags || ' -target ' || "resource";
        END LOOP;
        RETURN flags;
    END;
$$ LANGUAGE plpgsql;

INSERT INTO executions (
    execution_id,
    is_rollback,
    pr_id,
    commit_id,
    base_ref,
    head_ref,
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
    approval_voters,
    min_approval_count,
    rejection_voters,
    min_rejection_count,
    plan_role_arn,
    deploy_role_arn
)
SELECT 
    execution_id,
    is_rollback,
    pr_id,
    commit_id,
    base_ref,
    head_ref,
    head_source_version,
    cfg_path,
    -- gets cfg dependencies that depend on cfg_path (essentially reversing the dependency tree)
    ARRAY(
        SELECT cfg_path
        FROM executions
        WHERE d.cfg_path=ANY(cfg_deps)
        AND commit_id = {commit_id}
        AND cardinality(new_resources) > 0
    ) AS cfg_deps,
    "status",
    plan_command,
    deploy_command,
    new_providers,
    new_resources,
    account_name,
    account_path,
    account_deps,
    voters,
    approval_voters,
    min_approval_count,
    rejection_voters,
    min_rejection_count,
    plan_role_arn,
    deploy_role_arn
FROM (
    SELECT
        'run-rollback-' || pr_id || '-' || substring(commit_id, 1, 4) || '-' || account_name || '-' || regexp_replace(cfg_path, '.*/', '') || '-'  || substr(md5(random()::text), 0, 4) AS execution_id,
        true AS is_rollback,
        pr_id,
        commit_id,
        base_ref,
        head_ref,
        head_source_version,
        cfg_path,
        cfg_deps,
        'waiting' AS "status",
        'terragrunt plan --terragrunt-working-dir ' || cfg_path || target_resources(new_resources) || ' -destroy' AS plan_command,
        'terragrunt destroy --terragrunt-working-dir ' || cfg_path || target_resources(new_resources) || ' -auto-approve' AS deploy_command,
        new_providers,
        new_resources,
        account_name,
        account_path,
        account_deps,
        voters,
        ARRAY[]::TEXT[] as approval_voters,
        min_approval_count,
        ARRAY[]::TEXT[] as rejection_voters,
        min_rejection_count,
        plan_role_arn,
        deploy_role_arn
    FROM executions
    WHERE commit_id = {commit_id} 
    AND cardinality(new_resources) > 0
    -- ensures that duplicate rollback executions are not created
    AND NOT exists (
        SELECT 1 
        FROM executions 
        WHERE is_rollback = true
        AND commit_id = {commit_id}
    )
) d
RETURNING *;
