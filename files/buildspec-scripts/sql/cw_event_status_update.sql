CREATE OR REPLACE FUNCTION pg_temp.status_all_update(text[]) 
    RETURNS VARCHAR AS $$
    DECLARE
        fail_count INT := 0;
        succcess_count INT := 0;
        i text;
    BEGIN
        FOREACH i IN ARRAY $1 LOOP
            CASE
                WHEN i = ANY('{running, waiting}'::TEXT[]) THEN
                    RETURN 'running';
                WHEN i = 'failed' THEN
                    fail_count := fail_count + 1;
                WHEN i = 'success' THEN
                    succcess_count := succcess_count + 1;
                ELSE
                    RAISE EXCEPTION 'status is unknown: %', i; 
            END CASE;
        END LOOP;

        CASE
            WHEN fail_count > 0 THEN
                RETURN 'failed';
            WHEN succcess_count > 0 THEN
                RETURN 'success';
            ELSE
                RAISE EXCEPTION 'Array is empty: %', $1; 
        END CASE;
    END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.cw_event_status_update(_execution_id VARCHAR, _status VARCHAR)
RETURNS VOID AS $$
    DECLARE
        cw RECORD;
        updated_commit_status VARCHAR;
        updated_pr_status VARCHAR;
    BEGIN
        RAISE NOTICE 'Updating executions status';

        UPDATE executions
        SET "status" = _status
        WHERE execution_id = _execution_id
        RETURNING pr_id, commit_id, is_rollback, is_base_rollback
        INTO cw;
        RAISE NOTICE 'Status: %', _status;

        RAISE NOTICE 'Updating commit_queue status';
        UPDATE commit_queue
        SET "status" = pg_temp.status_all_update(
            ARRAY(
                SELECT "status"
                FROM executions
                WHERE commit_id = cw.commit_id
                AND is_rollback = cw.is_rollback
                AND is_base_rollback = cw.is_base_rollback
            )
        )
        WHERE commit_id = cw.commit_id
        AND is_rollback = cw.is_rollback
        AND is_base_rollback = cw.is_base_rollback
        RETURNING "status"
        INTO updated_commit_status;
        RAISE NOTICE 'Status: %', updated_commit_status;

        RAISE NOTICE 'Updating pr_queue status';
        UPDATE pr_queue
        SET "status" = pg_temp.status_all_update(
            ARRAY(
                SELECT "status"
                FROM commit_queue
                WHERE pr_id = cw.pr_id
            )
        )
        WHERE pr_id = cw.pr_id
        RETURNING "status"
        INTO updated_pr_status;
        RAISE NOTICE 'Status: %', updated_pr_status;
    END;
$$ LANGUAGE plpgsql;

SELECT pg_temp.cw_event_status_update(:'execution_id', :'status');