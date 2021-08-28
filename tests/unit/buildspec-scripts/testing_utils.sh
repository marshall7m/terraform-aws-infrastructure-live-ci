#!/bin/bash

if [ -n "$MOCK_GIT_CMDS" ]; then
    source mock_git_cmds.sh
fi

if [ -n "$MOCK_AWS_CMDS" ]; then
    source mock_aws_cmds.sh
fi

log() {
  declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
  local log_message=$1
  local log_priority=$2

  #check if level exists
  [[ ${levels[$log_priority]} ]] || return 1

  #check if level is enough
  # returns exit status 0 instead of 2 to prevent `set -e ` from exiting if log priority doesn't meet log level
  (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return

  # redirects log message to stderr (>&2) to prevent cases where sub-function
  # uses log() and sub-function stdout results and log() stdout results are combined
  echo "${log_priority} : ${log_message}" >&2
}

run_only_test() {
  if [ "$BATS_TEST_NUMBER" -ne "$1" ]; then
    skip
  fi
}

setup_tg_env() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

    export TESTING_TMP_DIR=$(mktemp -d)
	log "TESTING_TMP_DIR: $TESTING_TMP_DIR" "DEBUG"
	chmod u+x "$TESTING_TMP_DIR"
	log "Changing directory to TESTING_TMP_DIR" "DEBUG"
	cd $TESTING_TMP_DIR
}

setup_metadb() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	export METADB_DOCKER_COMPOSE_PATH="$PWD/docker-compose.yml"
	export VOLUME_DATA_DIR="./docker_pgsql_volume"
	export CONTAINER_NAME="metadb"
	export POSTGRES_USER="postgres"
    export POSTGRES_PASSWORD="testing_password"
    export POSTGRES_DB="postgres"
	export TESTING_POSTGRES_USER="testing_user"
	export TESTING_POSTGRES_DB="testing_metadb"

	if [ -z "$METADB_TYPE" ]; then
		log "METADB_TYPE is not set (local|aws)" "ERROR"
		return 1
	fi

	if [ "$METADB_TYPE" == "local" ]; then
		log "Hosting metadb on local postgres database" "INFO"

		log "Removing local postgres data to allow postgres image to run *.sh | *.sql scripts within host" "DEBUG"
		rm -rf "$VOLUME_DATA_DIR"

		log "Running Docker Compose" "INFO"
		docker-compose up -d
		
		log "Container Logs:" "DEBUG"
		log "$(docker logs "$CONTAINER_NAME")" "DEBUG"
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
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	if [ "$METADB_TYPE" == "local" ]; then
		docker-compose down -v 
	fi
}

teardown_tg_env() {
  if [ $BATS_TEST_COMPLETED ]; then
    rm -rf $TESTING_TMP_DIR
  else
    echo "Did not delete $TESTING_TMP_DIR, as test failed"
  fi
}

setup_existing_provider() {
	cat << EOF > $TESTING_TMP_DIR/main.tf

provider "time" {}

resource "time_static" "test" {}

EOF
    # 'EOF' to escape $
    cat << 'EOF' > $TESTING_TMP_DIR/terragrunt.hcl

terraform {
    source = "${get_terragrunt_dir()}///"
}
EOF

    setup_terragrunt_apply
}

setup_new_provider() {
	declare -a new_providers=("random" "null")
    for provider in "${new_providers[@]}"; do
        cat << EOF >> ./new_provider.tf

provider "$provider" {}
EOF
    done
}

setup_new_provider_with_resource() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	declare -a new_providers=("random")
	declare -a new_providers=("random_id.test")
	cat << EOF > $TESTING_TMP_DIR/new_provider.tf

provider "$new_providers" {}

resource "random_id" "test" {
    byte_length = 8
}
EOF
}

setup_terragrunt_apply() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	# applies new providers and adds new provider resources to tfstate
    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve
}

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	modify_paths=()

	while (( "$#" )); do
		case "$1" in
			--clone-url)
				if [ -n "$2" ]; then
					clone_url="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--clone-destination)
				clone_destination="$2"
				shift 2
				;;
			--terragrunt-working-dir)
				terragrunt_working_dir="$2"
				shift 2
				;;
			--skip-terraform-state-setup)
				skip_terraform_state_setup=true
				shift
				;;
			--modify)
				modify_paths+=("$2")
				shift 2
				;;
			*)
				echo "Unknown Option: $1"
				exit 1
				;;
		esac
	done
}

clone_testing_repo() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	local clone_url=$1
	local clone_destination=$2

	local_clone_git=$clone_destination/.git

	if [ ! -d $local_clone_git ]; then
		git clone "$clone_url" "$clone_destination"
	else
		log ".git already exists in clone destination" "INFO"
	fi
}

query() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	# export PGUSER=$TESTING_POSTGRES_USER
	# export PGDATABASE=$TESTING_POSTGRES_DB
	
	local arg=$1
	if [ -z "$METADB_TYPE" ]; then
		log "METADB_TYPE is not set (local|aws)" "ERROR"
		return 1
	fi

	if [ "$METADB_TYPE" == "local" ]; then
		docker exec -it "$CONTAINER_NAME" psql -U "$TESTING_POSTGRES_USER" -d "$TESTING_POSTGRES_DB" -c "$arg"
	fi
}

setup_test_env() {
	parse_args "$@"

	log "Modify list: ${modify_paths[*]}"  "DEBUG"
	clone_testing_repo $clone_url $clone_destination

	if [ -z "$skip_terraform_state_setup" ]; then
		log "Applying all dirs" "DEBUG"

		apply_out=$(terragrunt run-all apply \
			--terragrunt-non-interactive \
			--terragrunt-include-external-dependencies \
			--terragrunt-working-dir "$terragrunt_working_dir" \
			-auto-approve \
			2>&1
		)

		if [ "${#modify_paths[@]}" -eq 0 ]; then
			log "No --modify dirs were defined -- All Terragrunt directory plans will be up-to-date" "INFO"
		else
			for dir in "${modify_paths[@]}"; do
			
				log "Modifying state for directory: $dir" "DEBUG"
				terragrunt destroy \
					--terragrunt-strict-include \
					--terragrunt-non-interactive \
					--terragrunt-ignore-external-dependencies \
					--terragrunt-working-dir "$dir" \
					-auto-approve
			done
		fi
	else 
		log "Skipping testing repo setup" "INFO"
	fi
}

