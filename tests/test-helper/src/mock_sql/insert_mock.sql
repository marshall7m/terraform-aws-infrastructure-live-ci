DO $$
    DECLARE
        count INT := :count
    BEGIN
        IF :count = NULL THEN
            -- creates duplicate rows of ':staging_table' to match mock_count only if ':staging_table' contains one item
            INSERT INTO :staging_table
            SELECT s.* 
            FROM :staging_table s, GENERATE_SERIES(1, :count)
            WHERE (SELECT COUNT(*) FROM :staging_table) = 1;
        END IF;

        IF :reset_identity_col = true THEN
            seq VARCHAR := (SELECT pg_get_serial_sequence(:target_table, id));
        
            PERFORM setval(seq, (SELECT COALESCE(MAX(id), 1) FROM :target_table));

            INSERT INTO :target_table (id, :insert_cols)
            SELECT
            nextval(seq),
            :insert_cols
            FROM :staging_table;
        ELSE
            INSERT INTO :target_table (:insert_cols)
            SELECT
            :insert_cols
            FROM :staging_table;
        END IF;
        
        DROP TABLE :staging_table;
        ALTER TABLE :target_table DISABLE TRIGGER :target_table || _default;  
    END;
$$ LANGUAGE plpgsql;
