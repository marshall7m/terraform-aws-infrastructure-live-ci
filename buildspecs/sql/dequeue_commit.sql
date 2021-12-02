CREATE OR REPLACE FUNCTION dequeue_commit()
    RETURNS SETOF commit_queue AS $$
    DECLARE
        res commit_queue%ROWTYPE;
    BEGIN
        UPDATE commit_queue
        SET "status" = 'running'
        WHERE id = (
            SELECT id
            FROM commit_queue
            WHERE is_rollback = true
            AND is_base_rollback = false
            AND "status" = 'waiting'
            ORDER BY id ASC
            LIMIT 1
        )
        RETURNING *
        INTO res;

        IF res IS NOT NULL THEN
            RETURN QUERY
            SELECT res.*;
        END IF;

        UPDATE commit_queue
        SET "status" = 'running'
        WHERE id = (
            SELECT id
            FROM commit_queue
            WHERE is_base_rollback = true
            AND is_rollback = true
            AND "status" = 'waiting'
            ORDER BY id ASC
            LIMIT 1
        )
        RETURNING *
        INTO res;

        IF res IS NOT NULL THEN
            RETURN QUERY
            SELECT res.*;
        END IF;

        UPDATE commit_queue
        SET "status" = 'running'
        WHERE id = (
            SELECT id
            from commit_queue
            WHERE is_base_rollback = false
            AND is_rollback = false
            AND "status" = 'waiting'
            ORDER BY id ASC
            LIMIT 1
        )
        RETURNING *
        INTO res;

        IF res IS NOT NULL THEN
            RETURN QUERY
            SELECT res.*;
        ELSE
            RAISE NOTICE 'No commits within target PR are waiting';
            RETURN QUERY
            SELECT res.*;
        END IF;
    END;
$$ LANGUAGE plpgsql;

SELECT * FROM dequeue_commit();