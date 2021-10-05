CREATE OR REPLACE FUNCTION status_all_update(text[]) RETURNS VARCHAR AS $$

    DECLARE
        fail_count INT := 0;
        succcess_count INT := 0;
        i text;
    BEGIN
        FOREACH i IN ARRAY $1 LOOP
            CASE
            WHEN i = 'running' THEN
                RETURN i;
            WHEN i = 'failed' THEN
                fail_count := fail_count + 1;
            WHEN i = 'success' THEN
                succcess_count := succcess_count + 1;
            ELSE
                RAISE EXCEPTION 'status is unknown: %', i; 
            END CASE;
        END LOOP;
        IF fail_count > 0 THEN
            RETURN 'failed';
        ELSE
            RETURN 'success';
        END IF;
    END;
$$ LANGUAGE plpgsql;

DO $$
    DECLARE
        executed_commit_id VARCHAR;
        updated_commit_id VARCHAR;
        updated_commit_status VARCHAR;
        updated_pr_id INTEGER;
        updated_pr_status VARCHAR;
    BEGIN
        UPDATE executions
        SET "status" = "status"
        WHERE execution_id = execution_id
        RETURNING commit_id
        INTO executed_commit_id;

        RAISE NOTICE 'Commit ID: %', executed_commit_id;

        SELECT status_all_update(ARRAY(
            SELECT "status"
            FROM executions 
            WHERE commit_id = executed_commit_id
        ))
        INTO updated_commit_status;

        UPDATE commit_queue
        SET "status" = updated_commit_status
        WHERE commit_id = executed_commit_id
        AND updated_commit_status != NULL
        RETURNING pr_id
        INTO updated_pr_id;

        RAISE NOTICE 'Updated commit status: %', updated_commit_status;

        SELECT status_all_update(ARRAY(
            SELECT "status"
            FROM commit_queue 
            WHERE pr_id = updated_pr_id
        ))
        INTO updated_pr_status;

        UPDATE pr_queue
        SET "status" = updated_pr_status
        WHERE pr_id = updated_pr_id
        AND updated_pr_status != NULL
        RETURNING *
        INTO updated_pr_id;

        RAISE NOTICE 'Updated PR status: %', updated_pr_status;
    END;
$$ LANGUAGE plpgsql;