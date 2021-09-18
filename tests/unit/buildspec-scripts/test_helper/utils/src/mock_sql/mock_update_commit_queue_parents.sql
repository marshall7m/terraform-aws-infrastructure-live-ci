\i trigger_defaults/pr_queue.sql

INSERT INTO pr_queue
SELECT DISTINCT pr_id 
FROM commit_queue
ON CONFLICT (pr_id) DO NOTHING