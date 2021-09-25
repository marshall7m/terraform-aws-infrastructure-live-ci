setup_local_env() {

    DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

    export IMAGE_NAME="bats-testing:sandbox"
    export CONTAINER_NAME="metadb"
    export KEEP_METADB_OPEN=true
    export VOLUME_ENTRYPOINT_DIR="$DIR/docker_pgsql_init"
    export VOLUME_DATA_DIR="$DIR/docker_pgsql_volume"
    export VOLUME_REPO_DIR="$(git rev-parse --show-toplevel)"

    docker build -t "$IMAGE_NAME"

    docker-compose up --detach || exit 1

    docker exec -it "$CONTAINER_NAME" /bin/bash

}


teardown_local_env() {

	echo >&2 "FUNCNAME=$FUNCNAME"
    if [ -z "$KEEP_METADB_OPEN" ]; then
        docker-compose down -v 
        echo >&2 "Removing local postgres data to allow postgres image to run *.sh | *.sql scripts within host"
        rm -rf "$VOLUME_DATA_DIR"
    else
        echo >&2 "Keeping local db container running"
    fi
	
}

setup_local_env
