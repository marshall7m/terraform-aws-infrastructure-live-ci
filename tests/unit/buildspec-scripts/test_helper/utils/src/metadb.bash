#!/bin/bash

is_local_db_running() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	query "SELECT 1" || return 1
}

setup_metadb() {
	set -e

	log "FUNCNAME=$FUNCNAME" "DEBUG"

	export METADB_DOCKER_COMPOSE_PATH="$PWD/docker-compose.yml"
	export VOLUME_DATA_DIR="./docker_pgsql_volume"
	export CONTAINER_NAME="metadb"
	export POSTGRES_USER="postgres"
    export POSTGRES_PASSWORD="testing_password"
	export TESTING_POSTGRES_USER="testing_user"
	export TESTING_POSTGRES_DB="testing_metadb"

	if [ "$METADB_TYPE" == "local" ]; then
		if is_local_db_running; then
			log "Local postgres database container is already running" "INFO"
		else
			log "Hosting metadb on local postgres database" "INFO"
			log "Running Docker Compose" "INFO"
			docker-compose up -d
			
			log "Container Logs:" "DEBUG"
			log "$(docker logs "$CONTAINER_NAME")" "DEBUG"
		fi
	elif [ "$METADB_TYPE" == "aws" ]; then
		log "Using AWS RDS metadb" "INFO"
	else
		log "METADB_TYPE is not set (local|aws)" "ERROR"
	fi
}

clear_metadb_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	sql="""
	CREATE OR REPLACE FUNCTION truncate_if_exists(_schema VARCHAR, _catalog VARCHAR, _table VARCHAR) 
		RETURNS text 
		LANGUAGE plpgsql AS
		
	\$\$
	DECLARE 
		_full_table text := concat_ws('.', quote_ident(_schema), quote_ident(_table));
	BEGIN
		IF EXISTS (
			SELECT 
				1 
			FROM 
				INFORMATION_SCHEMA.TABLES 
			WHERE
				TABLE_SCHEMA = _schema AND
				TABLE_CATALOG = _catalog AND
				TABLE_NAME = _table
		)
		THEN
			EXECUTE 'TRUNCATE ' || _full_table ;
			RETURN 'Table truncated: ' || _full_table;
		ELSE
			RETURN 'Table does not exists: ' || _full_table;
		END IF;
	END;
	\$\$;

	SELECT truncate_if_exists('public', '$TESTING_POSTGRES_DB', 'executions');
	SELECT truncate_if_exists('public', '$TESTING_POSTGRES_DB', 'commit_queue');
	SELECT truncate_if_exists('public', '$TESTING_POSTGRES_DB', 'account_dim');
	SELECT truncate_if_exists('public', '$TESTING_POSTGRES_DB', 'pr_queue');

	"""
	query "$sql"
}

teardown_metadb() {
	set -e

	log "FUNCNAME=$FUNCNAME" "DEBUG"

	if [ "$METADB_TYPE" == "local" ]; then
		if [ -z "$KEEP_METADB_OPEN" ]; then
			docker-compose down -v 
			log "Removing local postgres data to allow postgres image to run *.sh | *.sql scripts within host" "DEBUG"
			rm -rf "$VOLUME_DATA_DIR"
		else
			log "Keeping local metadb container running" "INFO"
		fi
	fi
	
}