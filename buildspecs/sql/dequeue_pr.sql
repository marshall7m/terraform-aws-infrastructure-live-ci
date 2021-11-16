UPDATE
    pr_queue
SET
    status = 'running'
WHERE 
    id = (
        SELECT id
        FROM pr_queue
        WHERE "status" = 'waiting'
        ORDER BY id ASC
        LIMIT 1
    )
AND
    0 = (
        SELECT COUNT(*) 
        FROM commit_queue 
        WHERE "status" = 'waiting'
    )
RETURNING row_to_json(pr_queue.*);