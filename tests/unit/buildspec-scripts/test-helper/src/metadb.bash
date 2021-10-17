source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"

setup_metadb() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"
    psql -q -f "$DIR/sql/create_metadb_tables.sql"
}

clear_metadb_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
    DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"
    psql -q -v table_schema="public" -v table_catalog="$PGDATABASE" -f "$DIR/sql/clear_metadb_tables.sql"
}