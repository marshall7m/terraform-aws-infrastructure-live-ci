-- noqa: disable=PRS
CREATE OR REPLACE FUNCTION get_target_execution_ids() RETURNS TEXT[] AS $$
    BEGIN
        RETURN (
            WITH commit_executions AS (
                WITH target_commit AS (
                    SELECT DISTINCT commit_id, is_rollback 
                    FROM executions
                    WHERE "status" = 'waiting'
                )
                SELECT *
                FROM executions
                -- intentionally errors if there are more than one unique commit_id and/or is_rollback value
                WHERE commit_id = (SELECT commit_id FROM target_commit)
                AND is_rollback = (SELECT is_rollback FROM target_commit)
            )
            SELECT array_agg(execution_id::TEXT)
            FROM  commit_executions
            WHERE "status" = 'waiting'
            AND account_deps && (
                SELECT ARRAY(
                    SELECT DISTINCT account_name
                    FROM commit_executions
                    WHERE "status" = ANY(ARRAY['waiting', 'running', 'aborted', 'failed'])
                )
            )::TEXT[] = FALSE
            AND cfg_deps && (
                SELECT ARRAY(
                    SELECT DISTINCT cfg_path
                    FROM commit_executions
                    WHERE "status" = ANY(ARRAY['waiting', 'running', 'aborted', 'failed'])
                )
            )::TEXT[] = FALSE
        );
    EXCEPTION 
        WHEN SQLSTATE '21000' THEN 
            RAISE EXCEPTION 'More than one commit ID is waiting: %', (SELECT array_agg(commit_id) FROM (
                SELECT DISTINCT commit_id, is_rollback 
                FROM executions
                WHERE "status" = 'waiting'
            ) ids );
    END;
$$ LANGUAGE plpgsql;  -- noqa: L016
