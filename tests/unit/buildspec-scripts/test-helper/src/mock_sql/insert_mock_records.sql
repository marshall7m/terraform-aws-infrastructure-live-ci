CREATE OR REPLACE FUNCTION insert_mock_records (
    staging_table VARCHAR,
    target_table regclass,
    col_names VARCHAR,
    mock_count INT,
    reset_identity_col BOOLEAN,
    trigger VARCHAR
)
    RETURNS JSON AS $$ 
    DECLARE
        seq VARCHAR;
    BEGIN
        ALTER TABLE target_table ENABLE TRIGGER trigger;
        IF count > 0 THEN
            -- creates duplicate rows of 'staging_table' to match mock_count only if 'staging_table' contains one item
            INSERT INTO staging_table
            SELECT s.* 
            FROM staging_table s, GENERATE_SERIES(1, count)
            WHERE (SELECT COUNT(*) FROM staging_table) = 1;
        END IF;

        IF reset_identity_col = true THEN
            SELECT pg_get_serial_sequence(''' || target_table || ''', 'id') INTO seq;

            PERFORM setval(seq, COALESCE(max(id) + 1, 1), false) FROM target_table;

            INSERT INTO target_table (id, psql_cols)
            SELECT
            nextval(seq),
            psql_cols
            FROM staging_table;
        ELSE
            INSERT INTO target_table (psql_cols)
            SELECT psql_cols
            FROM staging_table
            RETURNING row_to_json(target_table.*);
        END IF;
        
        ALTER TABLE target_table DISABLE TRIGGER trigger;
    END;
$$ LANGUAGE plpgsql;