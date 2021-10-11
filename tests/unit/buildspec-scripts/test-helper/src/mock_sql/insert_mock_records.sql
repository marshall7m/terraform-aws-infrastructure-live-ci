CREATE OR REPLACE FUNCTION insert_mock_records (
    staging_table VARCHAR,
    target_table VARCHAR,
    col_names VARCHAR,
    mock_count INT,
    reset_identity_col BOOLEAN,
    trigger VARCHAR
)
    RETURNS JSON AS $$ 
    DECLARE
        seq VARCHAR;
        res RECORD;
    BEGIN
        EXECUTE format('
        SELECT array_to_string(array(
            SELECT concat(pg_attribute.attname) AS column_name
            FROM pg_catalog.pg_attribute
            INNER JOIN pg_catalog.pg_class 
            ON pg_class.oid = pg_attribute.attrelid
            INNER JOIN pg_catalog.pg_namespace 
            ON pg_namespace.oid = pg_class.relnamespace
            WHERE
                pg_attribute.attnum > 0
                AND NOT pg_attribute.attisdropped
                AND pg_namespace.nspname = ''%I''
                AND pg_class.relname = ''%I''
            ORDER BY
                attnum ASC
        ), '', '')', 'public', staging_table)
        INTO col_names;

        EXECUTE format('ALTER TABLE %I ENABLE TRIGGER %s', target_table, trigger);
        IF mock_count > 0 THEN
            RAISE INFO 'Duplicating rows to match mock_count';
            EXECUTE format('INSERT INTO %1$I SELECT s.* FROM %1$I s, GENERATE_SERIES(1, %2$s)', staging_table, mock_count);
        END IF;
        IF reset_identity_col = true THEN
            RAISE INFO 'Resetting identity column sequence';
            EXECUTE format('SELECT pg_get_serial_sequence(''%s'', ''id'')', target_table)
            INTO seq;
            -- EXECUTE format('PERFORM setval(%s, COALESCE(max(id) + 1, 1), false) FROM %I', seq, target_table);
            PERFORM format('setval(%s, COALESCE(max(id) + 1, 1), false) FROM %I', seq, target_table);
            RAISE INFO 'Inserting mock records into %', target_table;
            EXECUTE format('INSERT INTO %1$I (id, %2$s)
            SELECT 
                nextval(''%3$s''),
                %2$s
            FROM %4$I
            RETURNING *', target_table, col_names, seq, staging_table)
            INTO res;
            RETURN row_to_json(res);
        ELSE
            RAISE INFO 'Inserting mock records into %', target_table;
            EXECUTE format('INSERT INTO %1$I (%2$s)
            SELECT %2$s
            FROM %3$I
            RETURNING *', target_table, col_names, staging_table)
            INTO res;
            RETURN row_to_json(res);
        END IF;
        
        EXECUTE format('ALTER TABLE %I DISABLE TRIGGER %s', target_table, trigger);
    END;
$$ LANGUAGE plpgsql;