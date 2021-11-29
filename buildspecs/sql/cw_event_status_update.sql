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
        SET "status" = status_all_update(
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
        SET "status" = status_all_update(
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


SELECT pg_temp.cw_event_status_update({execution_id}, {status});
