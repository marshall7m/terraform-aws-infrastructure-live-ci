UPDATE commit_queue
SET "status" = 'running'
WHERE id = (
    SELECT id
    FROM commit_queue
    WHERE "status" = 'waiting'
    ORDER BY 
        is_rollback DESC NULLS LAST,
        is_base_rollback ASC NULLS LAST,
        id ASC
    LIMIT 1
)
RETURNING *;