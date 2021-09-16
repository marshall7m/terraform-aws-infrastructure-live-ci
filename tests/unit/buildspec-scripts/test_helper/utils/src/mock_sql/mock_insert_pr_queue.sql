CREATE OR REPLACE FUNCTION trig_pr_queue_default()
  RETURNS trigger
  LANGUAGE plpgsql AS
$func$
BEGIN
   IF NEW.pr_id IS NULL THEN
    SELECT MAX(pr.pr_id) + 1 INTO NEW.pr_id
    FROM pr_queue pr;
   END IF;

   IF NEW.status IS NULL THEN
    NEW.status := CASE (RANDOM() * 1)::INT
        WHEN 0 THEN 'success'
        WHEN 1 THEN 'failed'
        WHEN 2 THEN 'running'
        WHEN 3 THEN 'waiting'
    END;
   END IF;

   IF NEW.base_ref IS NULL THEN
    NEW.base_ref := (SELECT base_ref INTO NEW.pr_id
    FROM pr_queue pr
    LIMIT 1;)
   END IF;

   IF NEW.head_ref IS NULL THEN
    NEW.head_ref := 'feature-' || substr(md5(random()::text), 0, 5)
   END IF;

   RETURN NEW;
END
$func$;


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
IF (SELECT COUNT(*) FROM staging_pr_queue) = 1; THEN
  INSERT INTO staging_pr_queue
  SELECT *
  FROM staging_pr_queue
  JOIN (
    SELECT row_number() OVER () AS rn
    FROM GENERATE_SERIES(1, :mock_count) seq
  ) total_mock USING (rn);
END IF;

INSERT INTO pr_queue
SELECT *
FROM staging_pr_queue
RETURNING *;


DROP TABLE staging_pr_queue;
ALTER TABLE pr_queue DISABLE TRIGGER pr_queue_default;