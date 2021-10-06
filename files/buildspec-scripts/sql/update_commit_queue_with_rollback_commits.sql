INSERT INTO commit_queue (
    commit_id,
    is_rollback,
    pr_id,
    "status"
)

SELECT
    commit_id,
    true as is_rollback,
    :'pr_id',
    'waiting' as "status"
FROM (
    SELECT commit_id
    FROM commit_queue
    -- gets commit executions that created new provider resources
    WHERE commit_id = ANY(
        SELECT commit_id
        FROM executions
        WHERE pr_id = :'pr_id' 
            AND is_rolback = false 
            AND new_resources > 0
    )
) AS sub
;
ALTER TABLE commit_queue ALTER COLUMN id RESTART WITH max(id) + 1;