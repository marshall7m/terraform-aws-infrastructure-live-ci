#!/bin/bash

is_local_db_running() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	query -c "SELECT 1"  || return 1
}

setup_metadb() {

	log "FUNCNAME=$FUNCNAME" "DEBUG"

	if [ "$METADB_TYPE" == "local" ]; then
		DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
		export DOCKER_COMPOSE_DIR="$DIR/../../../"
		export VOLUME_DATA_DIR="$DOCKER_COMPOSE_DIR/docker_pgsql_volume"
		export VOLUME_ENTRYPOINT_DIR="$DOCKER_COMPOSE_DIR/docker_pgsql_init"
		export CONTAINER_NAME="metadb"
		export POSTGRES_USER="postgres"
		export POSTGRES_PASSWORD="testing_password"
		export TESTING_POSTGRES_USER="testing_user"
		export TESTING_POSTGRES_DB="testing_metadb"

		if is_local_db_running; then
			log "Local postgres database container is already running" "INFO"
		else
			log "Hosting metadb on local postgres database" "INFO"
			log "Running Docker Compose" "INFO"
			docker-compose --file "$DOCKER_COMPOSE_DIR/docker-compose.yml" up --detach || exit 1

			#TODO: Figure why set +e is needed even though scripts that source func don't have set -e
			set +e
			
			count=0
			timeout_sec=300
			sleep_sec=30

			log "Timeout (sec): $timeout_sec" "DEBUG"
			log "Sleep (sec): $sleep_sec" "DEBUG"
			is_local_db_running
			while [ $? -ne 0 ]; do
				if (( $count < $timeout_sec )); then
					log "Timeout has been reached -- exiting" "ERROR"
					exit 1
				fi
				
				log "Metadb is not ready yet -- sleeping $sleep_sec seconds" "INFO"
				sleep "$sleep_sec"
				count=$(( count + "$sleep_sec" ))
				log "Total wait time: $count" "DEBUG"
				is_local_db_running
			done

			log "Metadb is ready" "INFO"
			log "Container Logs:" "DEBUG"
			log "$(docker logs "$CONTAINER_NAME")" "DEBUG"
		fi
	elif [ "$METADB_TYPE" == "aws" ]; then
		log "Using AWS RDS metadb" "INFO"
		#TODO: export RDS credentials for psql query
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
	query -c "$sql"
}

drop_temp_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	query -c "DROP TABLE IF EXISTS staging_cfg_stack, queued_executions;"
}


teardown_metadb() {

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