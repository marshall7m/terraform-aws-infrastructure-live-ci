ALTER TABLE pr_queue ENABLE TRIGGER pr_queue_default;

PERFORM setval(public.pr_queue_id_seq, (SELECT COALESCE(MAX(id), 1) FROM pr_queue));

INSERT INTO pr_queue (id, pr_id)
SELECT
    nextval(public.pr_queue_id_seq) AS id,
    DISTINCT pr_id AS pr_id
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
