#!/bin/bash

parse_create_mock_tables_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	while (( "$#" )); do
		case "$1" in
			--account-stack)
				if [ -n "$2" ]; then
					account_stack=$( echo "$2" | jq '. | tojson')
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--pr-count)
				if [ -n "$2" ]; then
					pr_count="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--commit-count)
				if [ -n "$2" ]; then
					commit_count="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			*)
				echo "Unknown Option: $1"
				exit 1
				;;
		esac
	done
}

setup_testing_tpl_repo() {
	local clone_url=$1

	export TESTING_TMP_REPO_TPL_DIR=$(mktemp -d)
	log "TESTING_TMP_REPO_TPL_DIR: $TESTING_TMP_REPO_TPL_DIR" "DEBUG"

	log "Cloning template Github repository" "INFO"
	clone_testing_repo $clone_url $TESTING_TMP_REPO_TPL_DIR
}

setup_testing_env() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	export TESTING_TMP_DIR=$(mktemp -d)
	log "TESTING_TMP_DIR: $TESTING_TMP_DIR" "DEBUG"

	chmod u+x "$TESTING_TMP_DIR"
	log "Changing directory to tmp dir: $TESTING_TMP_DIR" "DEBUG"
	cd $TESTING_TMP_DIR
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
    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve
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

parse_tg_graph_deps() {
	parsed_stack=$(jq -n '{}')

    out=$(terragrunt graph-deps --terragrunt_working_dir "$TESTING_TMP_DIR")

    log "Terragrunt graph-dep command out:" "DEBUG"
    log "$out" "DEBUG"

    while read -r line; do
		parent=$( echo "$line" | grep -Po '"\K.+?(?="\s+\->)')
		log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"

		dep=$( echo "$line" | grep -Po '\->\s+"\K.+(?=";)')
		log "Dependency: $(printf "\n\t%s" "$dep")" "DEBUG"

        if [ "$parent" != "" ]; then
            parsed_stack=$( echo $parsed_stack \
                | jq --arg parent "$parent" --arg dep "$dep" '
                    (.[$parent]) |= . + [$dep]
                '
            )
        fi
    done <<< $out

    echo "$parsed_stack"
}

create_mock_tables() {
	parse_create_mock_tables_args
	
	if [ -n "$tg_directory" ]; then
		log ""
		cfg_stack_sql="""
		CREATE TEMP TABLE cfg_stack (
			cfg_path VARCHAR,
			cfg_deps VARCHAR
		);
		COPY cfg_stack (cfg_path, cfg_deps) FROM STDIN WITH (FORMAT CSV);
		"""
		parse_tg_graph_deps "$TESTING_TMP_DIR" | jq -r '. | @csv' | query "$cfg_stack_sql"
	fi

	account_stack_sql="""
	CREATE TEMP TABLE account_stack (
		account_path,
		account_deps
	);

	COPY account_stack (
		account_path,
		account_deps
	) FROM STDIN WITH (FORMAT CSV);
	"""

	echo "$account_stack" | jq -r '. | @csv' | query "$account_stack_sql"
	

	sql="""

	CREATE OR REPLACE FUNCTION random_between(low INT,  high INT) 
		RETURNS INT AS
	$$
	BEGIN
		RETURN floor(random()* (high-low + 1) + low);
	END;

	SELECT COUNT(*) FROM stack as stack_count;	

	INSERT INTO commit_queue (
		commit_id,
		pr_id,
		status,
		base_ref,
		head_ref,
		type
	)

	SELECT 
		GENERATE_UID(16) as commit_id
		random_between(1, 10) as pr_id
		(
            CASE (RANDOM() * 1)::INT
            WHEN 1 THEN 'success'
            WHEN 2 THEN 'failed'
            END
        ) as status,
		'master' as base_ref,
		'feature' || seq as head_ref
	OVER (PARTITION BY pr_id)
	FROM GENERATE_SERIES(1, 30) seq;

	
	INSERT INTO executions (
		execution_id,
        pr_id,
        commit_id,
        is_rollback_cfg,
        cfg_path,
		cfg_deps,
        account_deps,
        execution_status,
        plan_command,
        deploy_command,
        new_providers,
        new_resources,
        account_name,
        account_path,
        voters,
        approval_count,
        min_approval_count,
        rejection_count,
        min_rejection_count
	)
	SELECT
        GENERATE_UUID(8) as execution_id,
        RANDOM() * 2 as pr_id,
        GENERATE_UID(16) as commit_id,
        RANDOM() < 0.5 as is_rollback,
        RANDOM_STRING(4) || '/' || RANDOM_STRING(4) as cfg_path,
        (JOIN) as cfg_deps,
        '[' || RANDOM_STRING(4) || '/' || RANDOM_STRING(4)
        (
            CASE (RANDOM() * 3)::INT
            WHEN 0 THEN 'running'
            WHEN 1 THEN 'waiting'
            WHEN 2 THEN 'success'
            WHEN 3 THEN 'failed'
            END
        ) as execution_status,
        'terragrunt plan' || '--terragrunt-working-dir ' || cfg_path as plan_command,
        'terragrunt apply' || '--terragrunt-working-dir ' || cfg_path || '-auto-approve' as deploy_command,
        (
            CASE is_rollback
            WHEN 0 THEN '[]'
            WHEN 1 THEN '[' || RANDOM_STRING(4) || ']'
            END
        ) as new_providers, 
        (
            CASE is_rollback
            WHEN 0 THEN '[]'
            WHEN 1 THEN '[' || RANDOM_STRING(4) || ']'
            END
        ) as new_resources,
        RANDOM_STRING(4),
        RANDOM_STRING(4),
        '[' || RANDOM_STRING(4) || ']',
        RANDOM() * 2,
        RANDOM() * 2,
        RANDOM() * 2,
        RANDOM() * 2
    FROM GENERATE_SERIES(1, 10) seq;

	"""
	query "$sql"
}

# TODO:
# Setup execution/account dim based on repo structure
#     - Use mock function to create other arbitrary values
# create finished executions/commits in relation to account/commit tables
# 	- set flags for global values that will effect test results
# 		- account_paths
# 		- account_deps
# Create test records within test case for better visibility of what test is testing
