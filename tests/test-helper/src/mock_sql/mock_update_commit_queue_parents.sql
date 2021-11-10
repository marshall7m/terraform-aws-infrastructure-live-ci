ALTER TABLE pr_queue ENABLE TRIGGER pr_queue_default;

INSERT INTO pr_queue (pr_id, id)
OVERRIDING SYSTEM VALUE
SELECT
    DISTINCT c.pr_id,
    coalesce(pr.id, nextval(pg_get_serial_sequence('pr_queue', 'id')))
FROM commit_queue c
LEFT JOIN pr_queue pr
ON (pr.pr_id = c.pr_id)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE pr_queue DISABLE trigger pr_queue_default;