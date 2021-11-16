CREATE OR REPLACE FUNCTION dequeue_rollback_commit()
    RETURNS JSON AS $$
    DECLARE
        _id INT;
        res RECORD;
    BEGIN
        SELECT id
        INTO _id
        FROM commit_queue
        WHERE is_rollback = true
        AND "status" = 'waiting'
        ORDER BY id ASC
        LIMIT 1
        FOR UPDATE;

        IF _id IS NOT NULL THEN
            RAISE NOTICE 'Dequeuing rollback commit';
            
            EXECUTE format('UPDATE commit_queue
            SET "status" = ''running''
            WHERE id = %s
            RETURNING *', _id)
            INTO res;
            RETURN row_to_json(res.*);
        END IF;

        SELECT id
        INTO _id
        FROM commit_queue
        WHERE is_base_rollback = true
        AND "status" = 'waiting'
        ORDER BY id ASC
        LIMIT 1
        FOR UPDATE;

        IF _id IS NOT NULL THEN
            RAISE NOTICE 'Dequeuing base rollback commit';
            
            EXECUTE format('UPDATE commit_queue
            SET "status" = ''running''
            WHERE id = %s
            RETURNING *', _id)
            INTO res;
            RETURN row_to_json(res.*);
        ELSE
            RAISE NOTICE 'No rollback commits are waiting';
            RETURN NULL;
        END IF;
    END;
$$ LANGUAGE plpgsql;

SELECT dequeue_rollback_commit();