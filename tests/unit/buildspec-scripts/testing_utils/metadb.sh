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
    export POSTGRES_DB="postgres"
	export TESTING_POSTGRES_USER="testing_user"
	export TESTING_POSTGRES_DB="testing_metadb"

	check_metadb_type

	if [ "$METADB_TYPE" == "local" ]; then
		if is_local_db_running; then
			log "Local postgres database container is already running" "INFO"
		else
			log "Hosting metadb on local postgres database" "INFO"

			log "Removing local postgres data to allow postgres image to run *.sh | *.sql scripts within host" "DEBUG"
			rm -rf "$VOLUME_DATA_DIR"

			log "Running Docker Compose" "INFO"
			docker-compose up -d
			
			log "Container Logs:" "DEBUG"
			log "$(docker logs "$CONTAINER_NAME")" "DEBUG"
		fi
	fi
}

clear_metadb_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	sql="""
	TRUNCATE executions, account_dim, commit_queue;
	"""
	query "$sql"
}

teardown_metadb() {
	set -e

	log "FUNCNAME=$FUNCNAME" "DEBUG"

	check_metadb_type

	if [ -z "$KEEP_METADB_OPEN" ]; then
		if [ "$METADB_TYPE" == "local" ]; then
			docker-compose down -v 
		fi
	else
		log "Keeping metadb container running" "INFO"
	fi
}

check_metadb_type() {
	if [ -z "$METADB_TYPE" ]; then
		log "METADB_TYPE is not set (local|aws)" "ERROR"
		return 1
	fi
}

query() {
	set -e
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	# export PGUSER=$TESTING_POSTGRES_USER
	# export PGDATABASE=$TESTING_POSTGRES_DB
	
	local arg=$1

	check_metadb_type
	
	if [ "$METADB_TYPE" == "local" ]; then
		docker exec -it "$CONTAINER_NAME" psql -U "$TESTING_POSTGRES_USER" -d "$TESTING_POSTGRES_DB" -c "$arg"
	fi
}