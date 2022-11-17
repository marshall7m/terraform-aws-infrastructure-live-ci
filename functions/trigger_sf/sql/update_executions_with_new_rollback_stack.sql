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
$$ LANGUAGE plpgsql;  -- noqa: L016

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
    apply_command,
    new_providers,
    new_resources,
    account_name,
    account_path,
    account_deps,
    voters,
    min_approval_count,
    min_rejection_count,
    approval_voters,
    rejection_voters,
    plan_role_arn,
    apply_role_arn,
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
    apply_command,
    new_providers,
    new_resources,
    account_name,
    account_path,
    account_deps,
    voters,
    min_approval_count,
    min_rejection_count,
    approval_voters,
    rejection_voters,
    plan_role_arn,
    apply_role_arn,
    -- gets cfg dependencies that depend on cfg_path 
    -- by reversing the dependency tree
    array(
        SELECT cfg_path  -- noqa: L028
        FROM executions
        WHERE d.cfg_path = any(cfg_deps)  -- noqa: L028, L026
            AND commit_id = '{commit_id}'  -- noqa: L028
            AND cardinality(new_resources) > 0  -- noqa: L028
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
        apply_role_arn,
        ARRAY[]::TEXT[] AS approval_voters,  --noqa: L013, L019
        ARRAY[]::TEXT[] AS rejection_voters,  --noqa: L013, L019
        'run-rollback-' || pr_id || '-' || substring(
            commit_id, 1, 4
        ) || '-' || account_name || '-' || regexp_replace(
            cfg_path, '.*/', ''
        ) || '-' || substr(md5(random()::TEXT), 0, 4) AS execution_id,
        'terragrunt plan --terragrunt-working-dir ' || cfg_path
        || ' --terragrunt-iam-role ' || plan_role_arn || target_resources(
            new_resources
        ) || ' -no-color -destroy' AS plan_command,
        'terragrunt destroy --terragrunt-working-dir ' || cfg_path
        || ' --terragrunt-iam-role ' || apply_role_arn || target_resources(
            new_resources
        ) || ' -no-color -auto-approve' AS apply_command
    FROM executions
    WHERE commit_id = '{commit_id}'
          AND cardinality(new_resources) > 0
        -- ensures that duplicate rollback executions are not created
        AND NOT EXISTS (
            SELECT 1
            FROM executions
            WHERE is_rollback = TRUE
                  AND commit_id = '{commit_id}'
        )
) AS d  -- noqa: L025
RETURNING *;
