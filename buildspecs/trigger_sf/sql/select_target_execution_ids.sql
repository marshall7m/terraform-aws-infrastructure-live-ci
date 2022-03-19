DROP TABLE IF EXISTS queued_executions, commit_executions;
CREATE OR REPLACE FUNCTION arr_in_arr_count(TEXT[], TEXT[]) RETURNS INT AS $$ 
    -- Returns the total number of array values in the first array that's in the second array
    DECLARE
        total int := 0;
        i TEXT;
    BEGIN
        FOREACH i IN ARRAY $1 LOOP
            IF (SELECT i = ANY ($2)::BOOL) or i IS NULL THEN
                total := total + 1;
                RAISE NOTICE 'total: %', total;
            END IF;
        END LOOP;
        RETURN total;
    END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_target_execution_ids() RETURNS TEXT[] AS $$
    BEGIN
        -- CREATE TABLE commit_executions AS
        -- WITH target_commit AS (
        --     SELECT DISTINCT commit_id, is_rollback 
        --     FROM executions
        --     WHERE "status" = 'waiting'
        -- )
        -- SELECT *
        -- FROM executions
        -- -- intentionally errors if there are more than one unique commit_id and/or is_rollback value
        -- WHERE commit_id = (SELECT commit_id FROM target_commit)
        -- AND is_rollback = (SELECT is_rollback FROM target_commit);

        -- CREATE TABLE queued_executions AS
        -- SELECT *
        -- FROM commit_executions
        -- WHERE "status" = 'waiting';

        -- RAISE NOTICE 'Getting target executions';
        -- -- selects executions where all account/terragrunt config dependencies are successful
        -- RETURN (
        --     SELECT array_agg(execution_id::TEXT)
        --     FROM queued_executions
        --     -- where count of dependency array == the count of successful dependencies
        --     WHERE cardinality(account_deps) = arr_in_arr_count(
        --         account_deps, ( 
        --             SELECT ARRAY(
        --                 SELECT DISTINCT account_name
        --                 FROM commit_executions
        --                 GROUP BY account_name
        --                 HAVING COUNT(*) FILTER (WHERE "status" = 'succeeded') = COUNT(*)
        --                 OR COUNT(*) = 0
        --             )
        --         )
        --     )
        --     -- if account has no executions within commit_executions, then return true
        --     AND cardinality(cfg_deps) = arr_in_arr_count(
        --         cfg_deps, (
        --             SELECT ARRAY(
        --                 SELECT DISTINCT commit_executions.cfg_path
        --                 FROM commit_executions
        --                 WHERE "status" = 'succeeded'
        --             )
        --         )
        --     )
        -- );

        CREATE TABLE commit_executions AS
        WITH target_commit AS (
            SELECT DISTINCT commit_id, is_rollback 
            FROM executions
            WHERE "status" = 'waiting'
        )
        SELECT *
        FROM executions
        -- intentionally errors if there are more than one unique commit_id and/or is_rollback value
        WHERE commit_id = (SELECT commit_id FROM target_commit)
        AND is_rollback = (SELECT is_rollback FROM target_commit);

        RETURN (
            SELECT array_agg(execution_id::TEXT)
            FROM commit_executions
            WHERE "status" = 'waiting'
            AND account_deps && (
                SELECT ARRAY(
                    SELECT DISTINCT account_name
                    FROM commit_executions
                    WHERE "status" = ANY(ARRAY['waiting', 'running', 'aborted', 'failed'])
                )
            ) = FALSE
            AND cfg_deps && (
                SELECT ARRAY(
                    SELECT DISTINCT cfg_path
                    FROM commit_executions
                    WHERE "status" = ANY(ARRAY['waiting', 'running', 'aborted', 'failed'])
                )
            ) = FALSE
        );
    END;
$$ LANGUAGE plpgsql;


SELECT get_target_execution_ids();