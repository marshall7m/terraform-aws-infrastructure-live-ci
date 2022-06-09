-- noqa: disable=PRS
CREATE OR REPLACE FUNCTION table_exists(
    _schema VARCHAR, _catalog VARCHAR, _table VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS
$$
    BEGIN
        IF EXISTS (
            SELECT 1 
            FROM  INFORMATION_SCHEMA.TABLES 
            WHERE table_schema = _schema 
            AND table_catalog = _catalog 
            AND table_name = _table
        )
        THEN
            RETURN True;
        ELSE
            RETURN False;
        END IF;
    END;
$$;


CREATE OR REPLACE FUNCTION truncate_if_exists(
    _schema VARCHAR, _catalog VARCHAR, _table VARCHAR
)
RETURNS text
LANGUAGE plpgsql AS
$$
    DECLARE 
        _full_table TEXT := concat_ws('.', quote_ident(_schema), quote_ident(_table));
    BEGIN
        IF table_exists(_schema, _catalog, _table) = true THEN
            EXECUTE 'TRUNCATE ' || _full_table ;
            RETURN 'Table truncated: ' || _full_table;
        ELSE
            RETURN 'Table does not exists: ' || _full_table;
        END IF;
    END;
$$;

CREATE OR REPLACE FUNCTION reset_identity_col(_schema VARCHAR, _catalog VARCHAR, _table VARCHAR, _identity_col VARCHAR)
RETURNS TEXT
LANGUAGE plpgsql AS $$
    DECLARE 
        _full_table TEXT := concat_ws('.', quote_ident(_schema), quote_ident(_table));
        _reset_val INT := 1;
    BEGIN
        IF table_exists(_schema, _catalog, _table) THEN
            PERFORM setval(pg_get_serial_sequence(_table, _identity_col), _reset_val, false);
            RETURN format('Table: %s Reset column: %s Reset value: %s', _table, _identity_col, _reset_val);
        ELSE
            RETURN 'Table does not exists: ' || _full_table;
        END IF;
    END;
$$;


SELECT truncate_if_exists({table_schema}, {table_catalog}, 'executions');
SELECT truncate_if_exists({table_schema}, {table_catalog}, 'account_dim');
