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
            SELECT DISTINCT account_name 
            FROM account_dim
            WHERE account_name != NEW.account_name
            LIMIT random_between(0, (
                SELECT COUNT(*)
                FROM (
                    SELECT DISTINCT account_name 
                    FROM account_dim
                    WHERE account_name != NEW.account_name
                ) n
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

    IF NEW.is_rollback IS NULL THEN
        NEW.is_rollback := CASE (RANDOM() * .5)::INT
            WHEN 0 THEN false
            WHEN 1 THEN true
        END;
    END IF;

    IF NEW.is_base_rollback IS NULL THEN
        NEW.is_base_rollback := false;
    END IF;

    IF NEW.commit_id IS NULL THEN
        NEW.commit_id := substr(md5(random()::text), 0, 40);
    END IF;

    IF NEW.status IS NULL THEN
        NEW.status := COALESCE(status_all_update(
            ARRAY(
                SELECT "status"
                FROM executions
                WHERE is_rollback = NEW.is_rollback
                AND is_base_rollback = NEW.is_base_rollback
                AND commit_id = NEW.commit_id
            )
        ), 'waiting');
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
    OR NEW.is_base_rollback IS NULL
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
        NEW.status := COALESCE(status_all_update(
            ARRAY(
                SELECT "status"
                FROM commit_queue
                WHERE pr_id = NEW.pr_id
            )
        ), 'waiting');
    END IF;

    IF NEW.base_ref IS NULL THEN
        -- TODO: change to select distinct base_ref from pr queue or if null then 'master
        NEW.base_ref := 'master';
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
    LANGUAGE plpgsql AS $func$
    DECLARE
        account_dim_ref RECORD;
        queue_ref RECORD;
    BEGIN
        SELECT *
        FROM account_dim
        WHERE account_name = NEW.account_name
        INTO account_dim_ref;

        SELECT *
        FROM commit_queue
        JOIN (
            SELECT *
            FROM pr_queue
            WHERE pr_id = NEW.pr_id
        ) pr_queue
        ON (commit_queue.pr_id = pr_queue.pr_id)
        WHERE commit_queue.commit_id = NEW.commit_id
        AND commit_queue.is_rollback = NEW.is_rollback
        AND commit_queue.is_base_rollback = NEW.is_base_rollback
        INTO queue_ref;

        IF NEW.account_name IS NULL THEN
            NEW.account_name := 'account-' || substr(md5(random()::text), 0, 4);
        END IF;

        IF NEW.account_path IS NULL THEN
            IF account_dim_ref.account_path IS NULL THEN
                NEW.account_path := NEW.account_name || '/' || substr(md5(random()::text), 0, 8);
            ELSE
                NEW.account_path := account_dim_ref.account_path;
            END IF;
        END IF;

        IF NEW.account_deps IS NULL THEN
            NEW.account_deps := COALESCE(account_dim_ref.account_deps, ARRAY(
                SELECT account_name 
                FROM account_dim
                LIMIT random_between(0, 1)
            ));
        END IF;

        IF NEW.min_approval_count IS NULL THEN
            NEW.min_approval_count := COALESCE(account_dim_ref.min_approval_count, random_between(1, 2));
        END IF;
    
        IF NEW.approval_count IS NULL THEN
            NEW.approval_count := random_between(0, NEW.min_approval_count);
        END IF;

        IF NEW.min_rejection_count IS NULL THEN
            NEW.min_rejection_count := COALESCE(account_dim_ref.min_rejection_count, random_between(1, 2));
        END IF;

        IF NEW.rejection_count IS NULL THEN
            NEW.rejection_count := random_between(0, NEW.min_rejection_count);
        END IF;

        IF NEW.voters IS NULL THEN
            NEW.voters := COALESCE(account_dim_ref.voters, ARRAY['voter-' || substr(md5(random()::text), 0, 4)]);
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
            NEW.base_ref := COALESCE(queue_ref.base_ref, 'master');
        END IF;

        IF NEW.head_ref IS NULL THEN
            NEW.head_ref := COALESCE(queue_ref.head_ref, 'feature-' || substr(md5(random()::text), 0, 5));
        END IF;

        IF NEW.base_source_version IS NULL THEN
            NEW.base_source_version := 'refs/heads/' || NEW.base_ref || '^{' || substr(md5(random()::text), 0, 40) || '}';
        END IF;

        IF NEW.head_source_version IS NULL THEN
            NEW.head_source_version := 'refs/pull/' || NEW.pr_id || '/head^{' || NEW.commit_id || '}';
        END IF;

        IF NEW.is_base_rollback IS NULL THEN
            NEW.is_base_rollback := false;
        END IF;

        IF NEW.plan_command IS NULL THEN
            NEW.plan_command := CASE
                WHEN NEW.is_rollback = 't' AND NEW.is_base_rollback = 'f' THEN 
                    'terragrunt destroy ' || '--terragrunt-working-dir ' || NEW.cfg_path
                ELSE
                    'terragrunt plan ' || '--terragrunt-working-dir ' || NEW.cfg_path
            END;
        END IF;

        IF NEW.deploy_command IS NULL THEN
            NEW.deploy_command := CASE
                WHEN NEW.is_rollback = 't' AND NEW.is_base_rollback = 'f' THEN 
                    'terragrunt destroy ' || '--terragrunt-working-dir ' || NEW.cfg_path || ' -auto-approve'
                ELSE
                    'terragrunt apply ' || '--terragrunt-working-dir ' || NEW.cfg_path || ' -auto-approve'
            END;
        END IF;

        IF NEW.is_rollback IS NULL THEN
            NEW.is_rollback := CASE (RANDOM() * .5)::INT
                WHEN 0 THEN false
                WHEN 1 THEN true
            END;
        END IF;

        IF NEW.new_providers IS NULL THEN
            NEW.new_providers := CASE
                WHEN NEW.is_rollback = 'f' THEN ARRAY[]::TEXT[]
                WHEN NEW.is_rollback = 't' THEN ARRAY['provider/' || substr(md5(random()::text), 0, 5)]
            END;
        END IF;

        IF NEW.new_resources IS NULL THEN
            NEW.new_resources := CASE
                WHEN NEW.is_rollback = 'f' THEN ARRAY[]::TEXT[]
                WHEN NEW.is_rollback = 't' THEN ARRAY['resource.' || substr(md5(random()::text), 0, 5)]
            END;
        END IF;

        RETURN NEW;
    END;
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
    OR NEW.is_base_rollback IS NULL
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

INSERT INTO pr_queue (id, pr_id, base_ref, head_ref, "status")
OVERRIDING SYSTEM VALUE
SELECT
    coalesce(id, nextval(pg_get_serial_sequence('pr_queue', 'id'))) AS id,
    e.pr_id,
    e.base_ref,
    e.head_ref,
    e."status"
FROM (
    SELECT
        pr_id,
        base_ref,
        head_ref,
        "status"
    FROM executions
) e
LEFT JOIN pr_queue p
ON (
    e.pr_id = p.pr_id
)
ON CONFLICT (id) DO NOTHING;


CREATE OR REPLACE FUNCTION trig_executions_update_parents()
RETURNS TRIGGER AS $$
    BEGIN
        INSERT INTO commit_queue (id, commit_id, is_rollback, is_base_rollback, pr_id, "status")
        OVERRIDING SYSTEM VALUE
        SELECT
            coalesce(id, nextval(pg_get_serial_sequence('commit_queue', 'id'))) AS id,
            e.commit_id,
            e.is_rollback,
            e.is_base_rollback,
            e.pr_id,
            e."status"
        FROM (
            SELECT
                commit_id,
                is_rollback,
                is_base_rollback,
                pr_id,
                "status"
            FROM executions
        ) e
        LEFT JOIN commit_queue c
        ON (
            e.commit_id = c.commit_id
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO account_dim (
            account_name,
            account_path,
            account_deps,
            min_approval_count,
            min_rejection_count,
            voters
        )
        SELECT
            account_name,
            account_path,
            account_deps,
            min_approval_count,
            min_rejection_count,
            voters
        FROM executions
        ON CONFLICT (account_name) DO NOTHING;

        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS executions_update_parents ON public.executions;
CREATE TRIGGER executions_update_parents
    AFTER UPDATE ON executions
    FOR EACH ROW
    EXECUTE PROCEDURE trig_executions_update_parents();

CREATE OR REPLACE FUNCTION trig_commit_queue_update_parents()
RETURNS TRIGGER AS $$
    BEGIN
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

        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS commit_queue_update_parents ON public.commit_queue;
CREATE TRIGGER commit_queue_update_parents
    AFTER UPDATE ON commit_queue
    FOR EACH ROW
    EXECUTE PROCEDURE trig_commit_queue_update_parents();