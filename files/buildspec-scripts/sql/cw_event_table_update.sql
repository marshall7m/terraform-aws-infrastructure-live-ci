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

CREATE OR REPLACE FUNCTION pg_temp.cw_event_table_update (_execution_id VARCHAR, _status VARCHAR)
    RETURNS VOID AS $$
    DECLARE
        cw_event RECORD;
        updated_commit_status VARCHAR;
        updated_pr_status VARCHAR;
    BEGIN
        RAISE NOTICE 'execution_id: %', _execution_id;

        EXECUTE format('UPDATE executions
        SET "status" = %s
        WHERE execution_id = %s
        RETURNING pr_id, commit_id, is_rollback
        ', _status, _execution_id)
        INTO cw_event;

        RAISE NOTICE 'Updated execution status: %', _status;

        RAISE NOTICE 'Commit ID: %', cw_event.commit_id;

        SELECT pg_temp.status_all_update(ARRAY(
            SELECT "status"
            FROM executions 
            WHERE commit_id = cw_event.commit_id
            AND is_rollback = cw_event.is_rollback
        ))
        INTO updated_commit_status;

        UPDATE commit_queue
        SET "status" = updated_commit_status
        WHERE commit_id = cw_event.commit_id
        AND is_rollback = cw_event.is_rollback;

        RAISE NOTICE 'Updated commit status: %', updated_commit_status;

        RAISE NOTICE 'PR ID: %', cw_event.pr_id;

        SELECT pg_temp.status_all_update(ARRAY(
            SELECT "status"
            FROM commit_queue 
            WHERE pr_id = cw_event.pr_id
        ))
        INTO updated_pr_status;

        UPDATE pr_queue
        SET "status" = updated_pr_status
        WHERE pr_id = cw_event.pr_id;

        RAISE NOTICE 'Updated PR status: %', updated_pr_status;
    END;
$$ LANGUAGE plpgsql;

SELECT pg_temp.cw_event_table_update(:'execution_id', :'status');