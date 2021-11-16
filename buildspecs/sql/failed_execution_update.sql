CREATE OR REPLACE FUNCTION pg_temp.failed_execution_update(_commit_id VARCHAR, _base_commit_id VARCHAR, _pr_id INT)
    RETURNS VOID AS $$
    BEGIN

        RAISE NOTICE '_commit_id: %', _commit_id;
        RAISE NOTICE '_base_commit_id: %', _base_commit_id;
        RAISE NOTICE '_pr_id: %', _pr_id;

        RAISE NOTICE 'Aborting deployments depending on failed execution';
        UPDATE executions
        SET "status" = 'aborted'
        WHERE "status" = 'waiting'
        AND commit_id = _commit_id
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