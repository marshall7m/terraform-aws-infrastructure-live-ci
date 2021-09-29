DO $$		
    DECLARE
        seq VARCHAR;
    BEGIN
        
        ALTER TABLE pr_queue ENABLE TRIGGER pr_queue_default;

        SELECT pg_get_serial_sequence('pr_queue', 'id') INTO seq;
        PERFORM setval(seq, COALESCE(max(id) + 1, 1), false) FROM pr_queue;

        INSERT INTO pr_queue (id, pr_id)
        SELECT
            nextval(seq),
            pr_id
        FROM commit_queue
        WHERE NOT EXISTS (
            SELECT *
            FROM pr_queue
            WHERE pr_id IN (
                SELECT DISTINCT pr_id
                FROM commit_queue
            )
        );

        ALTER TABLE pr_queue DISABLE trigger pr_queue_default;
    END;
$$ LANGUAGE plpgsql;