-- noqa: disable=PRS,LXS

CREATE OR REPLACE FUNCTION random_between(low INT, high INT) RETURNS INT
LANGUAGE plpgsql AS
$$
BEGIN
    RETURN floor(random()* (high-low + 1) + low);
END;
$$;

CREATE OR REPLACE FUNCTION trig_account_dim_default()
RETURNS TRIGGER
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
        NEW.account_deps := ARRAY[]::TEXT[];
    END IF;

    IF NEW.min_approval_count IS NULL THEN
        NEW.min_approval_count := random_between(1, 2);
    END IF;

    IF NEW.min_rejection_count IS NULL THEN
        NEW.min_rejection_count := random_between(1, 2);
    END IF;

    IF NEW.voters IS NULL THEN
        NEW.voters := ARRAY[]::TEXT[];
    END IF;

   RETURN NEW;
END
$func$;  --noqa: L016

DROP TRIGGER IF EXISTS account_dim_default ON account_dim;

CREATE TRIGGER account_dim_default
BEFORE INSERT ON account_dim
FOR EACH ROW
WHEN (
    new.account_name IS NULL
    OR new.account_path IS NULL
    OR new.account_deps IS NULL
    OR new.min_approval_count IS NULL
    OR new.min_rejection_count IS NULL
    OR new.voters IS NULL
)
EXECUTE PROCEDURE trig_account_dim_default();
ALTER TABLE account_dim DISABLE TRIGGER account_dim_default;

CREATE OR REPLACE FUNCTION trig_executions_default()
RETURNS TRIGGER
LANGUAGE plpgsql AS $func$
    DECLARE
        account_dim_ref RECORD;
    BEGIN
        SELECT *
        FROM account_dim
        WHERE account_name = NEW.account_name
        INTO account_dim_ref;

        IF NEW.account_name IS NULL THEN
            NEW.account_name := 'account-' || substr(md5(random()::text), 0, 4);
        END IF;

        IF NEW.account_path IS NULL THEN
            NEW.account_path := COALESCE(account_dim_ref.account_path, NEW.account_name);
        END IF;

        IF NEW.account_deps IS NULL THEN
            NEW.account_deps := ARRAY[]::TEXT[];
        END IF;

        IF NEW.min_approval_count IS NULL THEN
            NEW.min_approval_count := COALESCE(account_dim_ref.min_approval_count, random_between(1, 2));
        END IF;

        IF NEW.min_rejection_count IS NULL THEN
            NEW.min_rejection_count := COALESCE(account_dim_ref.min_rejection_count, random_between(1, 2));
        END IF;

        IF NEW.voters IS NULL THEN
            NEW.voters := ARRAY[]::TEXT[];
        END IF;

        IF NEW.approval_voters IS NULL THEN
            NEW.approval_voters := (SELECT (NEW.voters)[:NEW.min_approval_count]);
        END IF;

        IF NEW.rejection_voters IS NULL THEN
            NEW.rejection_voters := (SELECT (NEW.voters)[:NEW.min_rejection_count]);
        END IF;

        IF NEW.plan_role_arn IS NULL THEN
            NEW.plan_role_arn := COALESCE(account_dim_ref.plan_role_arn, NEW.account_name || '-plan-role');
        END IF;

        IF NEW.apply_role_arn IS NULL THEN
            NEW.apply_role_arn := COALESCE(account_dim_ref.apply_role_arn, NEW.account_name || '-deploy-role');
        END IF;

        IF NEW.cfg_deps IS NULL THEN
            NEW.cfg_deps := ARRAY[]::TEXT[];
        END IF;

        IF NEW.execution_id IS NULL THEN
            NEW.execution_id := 'run-' || substr(md5(random()::text), 0, 8);
        END IF;

        IF NEW.pr_id IS NULL THEN
            SELECT COALESCE(MAX(e.pr_id), 0) + 1 INTO NEW.pr_id
            FROM executions e;
        END IF;

        IF NEW.commit_id IS NULL THEN
            NEW.commit_id := substr(md5(random()::text), 0, 40);
        END IF;

        IF NEW.status IS NULL THEN
            NEW.status := CASE
                WHEN NEW.approval_voters IS NOT NULL AND CARDINALITY(NEW.approval_voters) = NEW.min_approval_count THEN 'succeeded'
                WHEN NEW.rejection_voters IS NOT NULL AND CARDINALITY(NEW.rejection_voters) = NEW.min_rejection_count  THEN 'failed'
                ELSE NULL
            END;
        END IF;
        
        IF NEW.cfg_path IS NULL THEN
            NEW.cfg_path := NEW.account_path || '/' || substr(md5(random()::text), 0, 8);
        END IF;

        IF NEW.base_ref IS NULL THEN
            NEW.base_ref := COALESCE((SELECT DISTINCT(e.base_ref) FROM executions e), 'master');
        END IF;

        IF NEW.head_ref IS NULL THEN
            SELECT DISTINCT(e.head_ref) INTO NEW.head_ref FROM executions e;
        END IF;

        IF NEW.plan_command IS NULL THEN
            NEW.plan_command := CASE
                WHEN NEW.is_rollback = 't' THEN 
                    'terragrunt destroy ' || '--terragrunt-working-dir ' || NEW.cfg_path
                WHEN NEW.is_rollback = 'f' THEN 
                    'terragrunt plan ' || '--terragrunt-working-dir ' || NEW.cfg_path
                ELSE NULL
            END;
        END IF;

        IF NEW.apply_command IS NULL THEN
            NEW.apply_command := CASE
                WHEN NEW.is_rollback = 't' THEN 
                    'terragrunt destroy ' || '--terragrunt-working-dir ' || NEW.cfg_path || ' -auto-approve'
                WHEN NEW.is_rollback = 'f' THEN 
                    'terragrunt apply ' || '--terragrunt-working-dir ' || NEW.cfg_path || ' -auto-approve'
                ELSE NULL
            END;
        END IF;

        IF NEW.new_providers IS NULL THEN
            NEW.new_providers := ARRAY[]::TEXT[];
        END IF;

        IF NEW.new_resources IS NULL THEN
            NEW.new_resources := ARRAY[]::TEXT[];
        END IF;

        RETURN NEW;
    END;
$func$;  --noqa: L016

DROP TRIGGER IF EXISTS executions_default ON executions;

CREATE TRIGGER executions_default
BEFORE INSERT ON executions
FOR EACH ROW
WHEN (
    new.execution_id IS NULL
    OR new.cfg_path IS NULL
    OR new.cfg_deps IS NULL
    OR new.plan_command IS NULL
    OR new.apply_command IS NULL
    OR new.new_providers IS NULL
    OR new.new_resources IS NULL
    OR new.pr_id IS NULL
    OR new.status IS NULL
    OR new.base_ref IS NULL
    OR new.head_ref IS NULL
    OR new.is_rollback IS NULL
    OR new.commit_id IS NULL
    OR new.account_name IS NULL
    OR new.account_path IS NULL
    OR new.account_deps IS NULL
    OR new.min_approval_count IS NULL
    OR new.min_rejection_count IS NULL
    OR new.voters IS NULL
)

EXECUTE PROCEDURE trig_executions_default();
ALTER TABLE executions DISABLE TRIGGER executions_default;
