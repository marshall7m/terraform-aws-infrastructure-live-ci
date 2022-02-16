DO \$\$
BEGIN
   IF NOT EXISTS (
      SELECT * 
      FROM pg_user 
      WHERE usename = '${metadb_ci_username}'
    ) THEN
        CREATE USER ${metadb_ci_username} WITH PASSWORD '${metadb_ci_password}';
        GRANT ${metadb_username} TO ${metadb_ci_username};
        GRANT CONNECT, TEMPORARY ON DATABASE ${metadb_name} TO ${metadb_ci_username};
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ${metadb_schema} TO ${metadb_ci_username};
        GRANT USAGE ON SCHEMA ${metadb_schema} TO ${metadb_ci_username};
        GRANT SELECT, INSERT, UPDATE, REFERENCES, TRIGGER ON executions TO ${metadb_ci_username};
        GRANT SELECT ON account_dim TO ${metadb_ci_username};
        ALTER ROLE ${metadb_ci_username} SET search_path TO ${metadb_schema};
   END IF;
END
\$\$;