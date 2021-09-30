CREATE OR REPLACE FUNCTION random_between(low INT, high INT) 
    RETURNS INT 
    LANGUAGE plpgsql AS
$$
BEGIN
    RETURN floor(random()* (high-low + 1) + low);
END;
$$;


-- account_dim

CREATE OR REPLACE FUNCTION trig_account_dim_default()
    RETURNS trigger
    LANGUAGE plpgsql AS
$func$
BEGIN
    IF NEW.account_name IS NULL THEN
        NEW.account_name := 'account-' || substr(md5(random()::text), 0, 4);
    END IF;

    IF NEW.account_path IS NULL THEN
        NEW.account_path := NEW.account_name || '/' || substr(md5(random()::text), 0, 8);
    END IF;

    IF NEW.account_deps IS NULL THEN
        NEW.account_deps := ARRAY(
            SELECT account_name 
            FROM account_dim
            LIMIT random_between(0, (
                SELECT COUNT(*)::INT
                FROM account_dim
                WHERE account_name != NEW.account_name
            ))
        );
    END IF;

    IF NEW.min_approval_count IS NULL THEN
        NEW.min_approval_count := random_between(1, 5);
    END IF;

    IF NEW.min_rejection_count IS NULL THEN
        NEW.min_rejection_count := random_between(1, 5);
    END IF;

    IF NEW.voters IS NULL THEN
        NEW.voters := ARRAY['voter-' || substr(md5(random()::text), 0, 4)];
    END IF;

   RETURN NEW;
END
$func$;

DROP TRIGGER IF EXISTS account_dim_default ON public.account_dim;

CREATE TRIGGER account_dim_default
BEFORE INSERT ON account_dim
FOR EACH ROW
WHEN (
    NEW.account_name IS NULL
    OR NEW.account_path IS NULL
    OR NEW.account_deps IS NULL
    OR NEW.min_approval_count IS NULL
    OR NEW.min_rejection_count IS NULL
    OR NEW.voters IS NULL
)
EXECUTE PROCEDURE trig_account_dim_default();

--commit_queue

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

-- executions

CREATE OR REPLACE FUNCTION trig_executions_default()
    RETURNS trigger
    LANGUAGE plpgsql AS
$func$
BEGIN

    IF NEW.account_name IS NULL THEN
        NEW.account_name := 'account-' || substr(md5(random()::text), 0, 4);
    END IF;

    IF NEW.account_path IS NULL THEN
        NEW.account_path := NEW.account_name || '/' || substr(md5(random()::text), 0, 8);
    END IF;

    IF NEW.account_deps IS NULL THEN
        NEW.account_deps := ARRAY(
            SELECT account_name 
            FROM account_dim
            LIMIT random_between(0, 1)
        );
    END IF;

    IF NEW.min_approval_count IS NULL THEN
        NEW.min_approval_count := random_between(1, 5);
    END IF;

    IF NEW.approval_count IS NULL THEN
        NEW.approval_count := random_between(1, NEW.min_approval_count);
    END IF;

    IF NEW.min_rejection_count IS NULL THEN
        NEW.min_rejection_count := random_between(1, 5);
    END IF;

    IF NEW.rejection_count IS NULL THEN
        NEW.rejection_count := random_between(0, NEW.min_rejection_count);
    END IF;

    IF NEW.voters IS NULL THEN
        NEW.voters := ARRAY['voter-' || substr(md5(random()::text), 0, 4)];
    END IF;

    IF NEW.cfg_path IS NULL THEN
        NEW.cfg_path := NEW.account_path || '/' || substr(md5(random()::text), 0, 8);
    END IF;

    IF NEW.cfg_deps IS NULL THEN
        NEW.cfg_deps := ARRAY(
            SELECT cfg_path 
            FROM executions
            LIMIT random_between(0, 1)
        );
    END IF;

    IF NEW.execution_id IS NULL THEN
        NEW.execution_id := 'run-' || substr(md5(random()::text), 0, 8);
    END IF;

    --use other table triggers and union updated NEW results?
    IF NEW.pr_id IS NULL THEN
        SELECT COALESCE(MAX(pr.pr_id), 0) + 1 INTO NEW.pr_id
        FROM pr_queue pr;
    END IF;

    IF NEW.commit_id IS NULL THEN
        NEW.commit_id := substr(md5(random()::text), 0, 40);
    END IF;

    IF NEW.status IS NULL THEN
        NEW.status := CASE
            WHEN NEW.approval_count = NEW.min_approval_count THEN 'success'
            WHEN NEW.rejection_count = NEW.min_rejection_count  THEN 'failed'
            ELSE 'running'
        END;
    END IF;
    
    IF NEW.base_ref IS NULL THEN
        NEW.base_ref := COALESCE((SELECT base_ref FROM pr_queue), 'master');
    END IF;

    IF NEW.head_ref IS NULL THEN
        NEW.head_ref := 'feature-' || substr(md5(random()::text), 0, 5);
    END IF;

    IF NEW.base_source_version IS NULL THEN
        NEW.base_source_version := 'refs/heads/' || NEW.base_ref || '^{' || substr(md5(random()::text), 0, 40) || '}';
    END IF;

    IF NEW.head_source_version IS NULL THEN
        NEW.head_source_version := 'refs/pull/' || NEW.pr_id || '/head^{' || NEW.commit_id || '}';
    END IF;

    IF NEW.plan_command IS NULL THEN
        NEW.plan_command := CASE
            WHEN NEW.is_rollback = 'f' THEN 'terragrunt plan ' || '--terragrunt-working-dir ' || NEW.cfg_path
            WHEN NEW.is_rollback = 't' THEN 'terragrunt destroy ' || '--terragrunt-working-dir ' || NEW.cfg_path
        END;
    END IF;

    IF NEW.deploy_command IS NULL THEN
        NEW.deploy_command := NEW.plan_command || ' -auto-approve';
    END IF;

    IF NEW.is_rollback IS NULL THEN
        NEW.is_rollback := CASE (RANDOM() * .5)::INT
            WHEN 0 THEN false
            WHEN 1 THEN true
        END;
    END IF;

    IF NEW.new_providers IS NULL THEN
		NEW.new_providers := CASE
            WHEN NEW.is_rollback = 'f' THEN ARRAY[NULL]
            WHEN NEW.is_rollback = 't' THEN ARRAY['provider/' || substr(md5(random()::text), 0, 5)]
        END;
    END IF;

    IF NEW.new_resources IS NULL THEN
		NEW.new_resources := CASE
            WHEN NEW.is_rollback = 'f' THEN ARRAY[NULL]
            WHEN NEW.is_rollback = 't' THEN ARRAY['resource.' || substr(md5(random()::text), 0, 5)]
        END;
    END IF;

    RETURN NEW;
END
$func$;

DROP TRIGGER IF EXISTS executions_default ON public.executions;

CREATE TRIGGER executions_default
BEFORE INSERT ON executions
FOR EACH ROW
WHEN (
    NEW.execution_id IS NULL
    OR NEW.cfg_path IS NULL
    OR NEW.cfg_deps IS NULL
    OR NEW.plan_command IS NULL
    OR NEW.deploy_command IS NULL
    OR NEW.new_providers IS NULL
    OR NEW.new_resources IS NULL
    OR NEW.pr_id IS NULL
    OR NEW.status IS NULL
    OR NEW.base_ref IS NULL
    OR NEW.head_ref IS NULL
    OR NEW.base_source_version IS NULL
    OR NEW.head_source_version IS NULL
    OR NEW.is_rollback IS NULL
    OR NEW.commit_id IS NULL
    OR NEW.account_name IS NULL
    OR NEW.account_path IS NULL
    OR NEW.account_deps IS NULL
    OR NEW.min_approval_count IS NULL
    OR NEW.approval_count IS NULL
    OR NEW.min_rejection_count IS NULL
    OR NEW.rejection_count IS NULL
    OR NEW.voters IS NULL
)

EXECUTE PROCEDURE trig_executions_default();


ALTER TABLE account_dim DISABLE trigger account_dim_default;
ALTER TABLE pr_queue DISABLE trigger pr_queue_default;
ALTER TABLE commit_queue DISABLE trigger commit_queue_default;
ALTER TABLE executions DISABLE trigger executions_default;
