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
    DECLARE
        _is_rollback BOOLEAN;
    BEGIN
        -- gets all executions from running commit
        CREATE TABLE commit_executions AS
            SELECT *
            FROM executions
            WHERE commit_id = (
                SELECT DISTINCT(commit_id)
                FROM executions
                WHERE "status" = 'waiting'
            );

        SELECT DISTINCT(is_rollback)
        INTO _is_rollback
        FROM commit_executions;

        -- get all executions that are waiting within commit
        CREATE TABLE queued_executions AS
            SELECT *
            FROM commit_executions
            WHERE "status" = 'waiting';

        IF _is_rollback = true THEN
            RAISE NOTICE 'Getting target rollback executions';
            -- selects executions where all account/terragrunt config dependencies are successful
            -- TODO: add doc
            RETURN (
                SELECT array_agg(execution_id::TEXT)
                FROM queued_executions
                WHERE account_path NOT IN (
                    SELECT c.account_deps
                    FROM   commit_executions t
                    LEFT JOIN unnest(t.account_deps) c(account_deps) 
                    ON true
                    WHERE "status" = 'running'
                    AND t.account_deps IS NOT NULL
                    AND cardinality(t.account_deps) > 0
                )
                AND cfg_path NOT IN (
                    SELECT c.cfg_deps
                    FROM   executions t
                    LEFT JOIN unnest(t.cfg_deps) c(cfg_deps)
                    ON true
                    WHERE "status" = 'running'
                    AND t.cfg_deps IS NOT NULL
                    AND cardinality(t.cfg_deps) > 0
                )
            );
            -- none of the cfg_deps are running/
        ELSE
            RAISE NOTICE 'Getting target deployment executions';
            -- selects executions where all account/terragrunt config dependencies are successful
            RETURN (
                SELECT array_agg(execution_id::TEXT)
                FROM queued_executions
                -- where count of dependency array == the count of successful dependencies
                WHERE cardinality(account_deps) = arr_in_arr_count(
                    account_deps, ( 
                        SELECT ARRAY(
                            SELECT DISTINCT account_name
                            FROM commit_executions
                            GROUP BY account_name
                            HAVING COUNT(*) FILTER (WHERE "status" = 'success') = COUNT(*)
                        )
                    )
                )
                AND cardinality(cfg_deps) = arr_in_arr_count(
                    cfg_deps, (
                        SELECT ARRAY(
                            SELECT DISTINCT commit_executions.cfg_path
                            FROM commit_executions
                            WHERE "status" = 'success'
                        )
                    )
                )
            );
        END IF;
    END;
$$ LANGUAGE plpgsql;


SELECT get_target_execution_ids();