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

CREATE OR REPLACE FUNCTION pg_temp.failed_execution_update(_commit_id VARCHAR, _base_commit_id VARCHAR, _pr_id INT)
    RETURNS VOID AS $$
    DECLARE
        commit_seq VARCHAR;
    BEGIN

        RAISE NOTICE '_commit_id: %', _commit_id;
        RAISE NOTICE '_base_commit_id: %', _base_commit_id;
        RAISE NOTICE '_pr_id: %', _pr_id;
        
        SELECT pg_get_serial_sequence('commit_queue', 'id')
        INTO commit_seq;

        RAISE NOTICE 'Aborting deployments depending on failed execution';
        UPDATE executions
        SET "status" = 'aborted'
        WHERE "status" = 'waiting'
        AND commit_id = _commit_id
        AND is_rollback = false;

        RAISE NOTICE 'Updating commit status';
        UPDATE commit_queue
        SET "status" = 'failed'
        WHERE commit_id = _commit_id
        AND is_rollback = false;

        IF EXISTS (
            SELECT commit_id
            FROM executions
            WHERE commit_id = _commit_id
            AND is_rollback = false 
            AND array_length(new_resources, 1) > 0
        ) THEN

            RAISE NOTICE 'Adding rollback commit to commit queue';

            INSERT INTO commit_queue (
                commit_id,
                is_rollback,
                is_base_rollback,
                pr_id,
                "status"
            )

            VALUES (
                _commit_id,
                true,
                false,
                _pr_id,
                'waiting'
            );

        END IF;

        RAISE NOTICE 'Adding base commit to commit queue';
        INSERT INTO commit_queue (
            commit_id,
            is_rollback,
            is_base_rollback,
            pr_id,
            "status"
        )

        VALUES (
            _base_commit_id,
            true,
            true,
            _pr_id,
            'waiting'
        );

        RETURN;
    END;
$$ LANGUAGE plpgsql;

SELECT pg_temp.failed_execution_update(:'commit_id', :'base_commit_id', :'pr_id');