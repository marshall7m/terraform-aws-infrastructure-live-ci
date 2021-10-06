CREATE OR REPLACE FUNCTION arr_in_arr_count(text[], text[]) RETURNS int AS $$
    
-- Returns the total number of array values in the first array that's in the second array

DECLARE
    total int := 0;
    i text;
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

-- gets all executions from running commit
SELECT *
INTO TEMP commit_executions
FROM executions
WHERE commit_id = (
    SELECT
        commit_id
    FROM
        commit_queue
    WHERE
        status = 'running'
)
AND
    is_rollback = (
        SELECT
            is_rollback
        FROM
            commit_queue
        WHERE
            status = 'running'
    )
;

-- get all executions that are waiting within commit
SELECT *
INTO queued_executions
FROM commit_executions
WHERE status = 'waiting'
;

-- selects executions where all account/terragrunt config dependencies are successful
SELECT execution_id
FROM queued_executions
-- where count of dependency array == the count of successful dependencies
WHERE cardinality(account_deps) = arr_in_arr_count(
    account_deps, ( 
        -- gets account names that have all successful executions within commit
        SELECT ARRAY(
            SELECT DISTINCT account_name
            FROM commit_executions
            GROUP BY account_name
            HAVING COUNT(*) FILTER (WHERE status = 'success') = COUNT(*)
        )
    )
)
AND
    cardinality(cfg_deps) = arr_in_arr_count(
        cfg_deps, (
        -- gets terragrunt config paths that have successful executions
            SELECT ARRAY(
                SELECT DISTINCT commit_executions.cfg_path
                FROM commit_executions
                WHERE status = 'success'
            )
        )
    )
INTO target_execution_ids
;
SELECT row_to_json(target_execution_ids);
