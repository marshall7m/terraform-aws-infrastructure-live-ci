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
        res record;
    BEGIN
        EXECUTE format('ALTER TABLE %I ENABLE TRIGGER %s', target_table, trigger);
        IF mock_count > 0 THEN
            RAISE INFO 'Duplicating rows to match mock_count';
            EXECUTE format('INSERT INTO %1$I SELECT s.* FROM %1$I s, GENERATE_SERIES(1, %2$s)', staging_table, mock_count);
        END IF;
        IF reset_identity_col = true THEN
            RAISE INFO 'Resetting indentity column sequence';
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