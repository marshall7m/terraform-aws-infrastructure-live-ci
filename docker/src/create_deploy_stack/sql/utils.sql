-- noqa: disable=PRS
CREATE OR REPLACE FUNCTION status_all_update(statuses text[])
RETURNS varchar AS $$
    DECLARE
        fail_count INT := 0;
        succcess_count INT := 0;
        i text;
    BEGIN
        FOREACH i IN ARRAY statuses LOOP
            CASE
                WHEN i = ANY('{running, waiting}'::TEXT[]) THEN
                    RETURN 'running';
                WHEN i = 'failed' THEN
                    fail_count := fail_count + 1;
                WHEN i = 'succeeded' THEN
                    succcess_count := succcess_count + 1;
                ELSE
                    RAISE EXCEPTION 'status is unknown: %', i; 
            END CASE;
        END LOOP;

        CASE
            WHEN fail_count > 0 THEN
                RETURN 'failed';
            WHEN succcess_count > 0 THEN
                RETURN 'succeeded';
            ELSE
                RAISE EXCEPTION 'Array is empty: %', statuses; 
        END CASE;
    END;
$$ LANGUAGE plpgsql;
