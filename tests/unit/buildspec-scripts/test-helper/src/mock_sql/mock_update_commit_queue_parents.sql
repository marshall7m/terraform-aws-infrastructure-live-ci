ALTER TABLE pr_queue ENABLE TRIGGER pr_queue_default;

INSERT INTO pr_queue (pr_id)
SELECT DISTINCT pr_id
FROM commit_queue
ORDER BY pr_id ASC
ON CONFLICT DO NOTHING;

ALTER TABLE pr_queue DISABLE trigger pr_queue_default;