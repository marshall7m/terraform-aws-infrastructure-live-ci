-- noqa: disable=PRS
CREATE OR REPLACE FUNCTION target_resources(TEXT[]) RETURNS TEXT AS $$
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
    cfg_path,
    "status",  -- noqa: L059
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
    deploy_role_arn,
    cfg_deps
)
SELECT
    execution_id,
    is_rollback,
    pr_id,
    commit_id,
    base_ref,
    head_ref,
    cfg_path,
    "status",  -- noqa: L059
    plan_command,
    deploy_command,
    new_providers,
    new_resources,
    account_name,
    account_path,
    account_deps,
    voters,
    min_approval_count,
    min_rejection_count,
    plan_role_arn,
    deploy_role_arn,
    approval_voters,
    rejection_voters,
    -- gets cfg dependencies that depend on cfg_path 
    -- by reversing the dependency tree
    ARRAY(
        SELECT cfg_path
        FROM executions
        WHERE d.cfg_path = ANY(cfg_deps)  -- noqa: L028, L026
            AND commit_id = '{commit_id}'
            AND CARDINALITY(new_resources) > 0
    ) AS cfg_deps
FROM (
    SELECT  --noqa: L034
        TRUE AS is_rollback,
        pr_id,
        commit_id,
        base_ref,
        head_ref,
        cfg_path,
        cfg_deps,
        'waiting' AS "status",  -- noqa: L059
        new_providers,
        new_resources,
        account_name,
        account_path,
        account_deps,
        voters,
        min_approval_count,
        min_rejection_count,
        plan_role_arn,
        deploy_role_arn,
        ARRAY[]::TEXT[] AS approval_voters,  --noqa: L013, L019
        ARRAY[]::TEXT[] AS rejection_voters,  --noqa: L013, L019
        'run-rollback-' || pr_id || '-' || SUBSTRING(
            commit_id, 1, 4
        ) || '-' || account_name || '-' || REGEXP_REPLACE(
            cfg_path, '.*/', ''
        ) || '-' || SUBSTR(MD5(RANDOM()::TEXT), 0, 4) AS execution_id,
        'terragrunt plan --terragrunt-working-dir ' || cfg_path
        || ' --terragrunt-iam-role ' || plan_role_arn || TARGET_RESOURCES(
            new_resources
        ) || ' -destroy' AS plan_command,
        'terragrunt destroy --terragrunt-working-dir ' || cfg_path
        || ' --terragrunt-iam-role ' || deploy_role_arn || TARGET_RESOURCES(
            new_resources
        ) || ' -auto-approve' AS deploy_command
    FROM executions
    WHERE commit_id = '{commit_id}'
          AND CARDINALITY(new_resources) > 0
        -- ensures that duplicate rollback executions are not created
        AND NOT EXISTS (
            SELECT 1
            FROM executions
            WHERE is_rollback = TRUE
                  AND commit_id = '{commit_id}'
        )
) AS d  -- noqa: L025
RETURNING *;
