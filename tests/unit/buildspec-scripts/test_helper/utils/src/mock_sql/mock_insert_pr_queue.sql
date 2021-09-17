CREATE OR REPLACE FUNCTION trig_pr_queue_default()
  RETURNS trigger
  LANGUAGE plpgsql AS
$func$
BEGIN
   IF NEW.pr_id IS NULL THEN
    SELECT COALESCE(MAX(pr.pr_id), 0) + 1 INTO NEW.pr_id
    FROM pr_queue pr;
   ELSE
    NEW.pr_id := OLD.pr_id;
   END IF;

   IF NEW.status IS NULL THEN
    NEW.status := CASE (RANDOM() * 1)::INT
        WHEN 0 THEN 'success'
        WHEN 1 THEN 'failed'
        WHEN 2 THEN 'running'
        WHEN 3 THEN 'waiting'
    END;
   ELSE
    NEW.status := OLD.status;
   END IF;

   IF NEW.base_ref IS NULL THEN
    SELECT COALESCE(pr.base_ref, 'master') INTO NEW.base_ref
    FROM pr_queue pr;
   ELSE
    NEW.base_ref := OLD.base_ref;
   END IF;

   IF NEW.head_ref IS NULL THEN
    NEW.head_ref := 'feature-' || substr(md5(random()::text), 0, 5);
   ELSE
    NEW.head_ref := OLD.head_ref;
   END IF;

   RETURN NEW;
END
$func$;

DROP TRIGGER IF EXISTS pr_queue_default ON public.pr_queue;

CREATE TRIGGER pr_queue_default
BEFORE INSERT ON pr_queue
FOR EACH ROW
WHEN (
    NEW.pr_id IS NULL
    OR NEW.status IS NULL
    OR NEW.base_ref IS NULL
    OR NEW.head_ref IS NULL
)
EXECUTE PROCEDURE trig_pr_queue_default();

-- creates duplicate rows of staging_pr_queue to match mock_count only if staging_pr_queue contains one item
INSERT INTO staging_pr_queue
SELECT s.* 
FROM staging_pr_queue s, GENERATE_SERIES(1, :mock_count)
WHERE (SELECT COUNT(*) FROM staging_pr_queue) = 1;

-- SELECT setval('public.pr_queue_id_seq', (select max(id) from pr_queue));

-- INSERT INTO pr_queue
-- OVERRIDING SYSTEM VALUE
-- SELECT
--   nextval('public.pr_queue_id_seq'),
--   *
-- FROM staging_pr_queue
-- RETURNING *;

SELECT
  nextval('public.pr_queue_id_seq'),
  *
FROM staging_pr_queue;

DROP TABLE staging_pr_queue;
ALTER TABLE pr_queue DISABLE TRIGGER pr_queue_default;  