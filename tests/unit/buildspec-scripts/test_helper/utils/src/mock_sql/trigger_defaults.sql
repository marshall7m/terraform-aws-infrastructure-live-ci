CREATE OR REPLACE FUNCTION trig_commit_queue_default()
  RETURNS trigger
  LANGUAGE plpgsql AS
$func$
BEGIN
   IF NEW.pr_id IS NULL THEN
    SELECT COALESCE(MAX(pr.pr_id), 0) + 1 INTO NEW.pr_id
    FROM commit_queue pr;
   END IF;

   IF NEW.status IS NULL THEN
    NEW.status := CASE (RANDOM() * 1)::INT
        WHEN 0 THEN 'success'
        WHEN 1 THEN 'failed'
        WHEN 2 THEN 'running'
        WHEN 3 THEN 'waiting'
    END;
   END IF;

   IF NEW.is_rollback IS NULL THEN
    NEW.is_rollback := CASE (RANDOM() * .5)::INT
        WHEN 0 THEN false
        WHEN 1 THEN true
    END;
   END IF;

   IF NEW.commit_id IS NULL THEN
    NEW.commit_id := substr(md5(random()::text), 0, 40);
   END IF;

   RETURN NEW;
END
$func$;

DROP TRIGGER IF EXISTS commit_queue_default ON public.commit_queue;

CREATE TRIGGER commit_queue_default
BEFORE INSERT ON commit_queue
FOR EACH ROW
WHEN (
    NEW.pr_id IS NULL
    OR NEW.status IS NULL
    OR NEW.is_rollback IS NULL
    OR NEW.commit_id IS NULL
)
EXECUTE PROCEDURE trig_commit_queue_default();


CREATE OR REPLACE FUNCTION trig_pr_queue_default()
  RETURNS trigger
  LANGUAGE plpgsql AS
$func$
BEGIN
   IF NEW.pr_id IS NULL THEN
    SELECT COALESCE(MAX(pr.pr_id), 0) + 1 INTO NEW.pr_id
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
    SELECT COALESCE(pr.base_ref, 'master') INTO NEW.base_ref
    FROM pr_queue pr;
   END IF;

   IF NEW.head_ref IS NULL THEN
    NEW.head_ref := 'feature-' || substr(md5(random()::text), 0, 5);
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

ALTER TABLE pr_queue DISABLE trigger pr_queue_default;
ALTER TABLE pr_queue DISABLE trigger commit_queue_default;
