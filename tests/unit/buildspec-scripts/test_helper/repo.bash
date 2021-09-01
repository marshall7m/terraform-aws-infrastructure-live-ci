#!/bin/bash
setup_test_file_repo() {
	local clone_url=$1

	export TESTING_REPO_TMP_CACHE_DIR=$(mktemp -d)
	log "TESTING_REPO_TMP_CACHE_DIR: $TESTING_REPO_TMP_CACHE_DIR" "DEBUG"

	log "Cloning Github repo to tmp" "INFO"
	clone_testing_repo $clone_url $TESTING_REPO_TMP_CACHE_DIR
}

setup_test_case_repo() {
	export TEST_CASE_REPO_DIR="$BATS_TMPDIR/test-repo"
	log "Cloning local template Github repo to test case tmp dir: $TEST_CASE_REPO_DIR" "INFO"
	clone_testing_repo $TESTING_REPO_TMP_CACHE_DIR $TEST_CASE_REPO_DIR
}

create_testing_repo_mock_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	# create mock executions/accounts/commits tables with finished status
}

modify_tg_path() {
	local tg_dir=$1

	tf_dir=$(terragrunt terragrunt-info --terragrunt_working_dir "$tg_dir" \
		| jq '.WorkingDir'
	)
	cat << EOF > $tf_dir/$(openssl rand -base64 12).tf

	output "test_case_$BATS_TEST_NUMBER" {
		value = "test"
	}

EOF
}

parse_tg_path_args() {
	declare -a modify_paths=()
	while (( "$#" )); do
		case "$1" in
			--modify-path)
				if [ -n "$2" ]; then
					modify_paths+=$1
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
		esac
	done
}

create_testing_repo_tg_env() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	parse_tg_path_args

	export TESTING_HEAD_REF="test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 6)"
	
	log "Creating testing branch: $TESTING_HEAD_REF" "INFO"
	git checkout -B "$TESTING_HEAD_REF"


	for dir in "${modify_paths[@]}"; do
		log "Directory: $dir" "INFO"

		log "Modifying configuration" "INFO"
		modify_tg_path "$dir"
	done

	log "Adding testing changes" "INFO"
	git add "$(git rev-parse --show-toplevel)/"
	
	git commit -m '$TESTING_HEAD_REF'
	export TESTING_COMMIT_ID=$(git log --pretty=format:'%h' -n 1)

	log "Adding testing commit to queue"
	sql="""
	INSERT INTO commit_queue (
		commit_id,
        pr_id,
        commit_status,
        base_ref,
        head_ref,
        is_rollback
	)
	VALUES (
		'$commit_id',
		1,
		'Waiting',
		'master',
		'$TESTING_HEAD_REF',
		'0'
	)
	"""
	query "$sql"

	log "Checking out commit before testing commit" "INFO"
	git checkout $(git rev-parse `git branch -r --sort=committerdate | tail -1`)
}

teardown_tmp_dir() {
  if [ $BATS_TEST_COMPLETED ]; then
    rm -rf $BATS_TMPDIR
  else
    echo "Did not delete $BATS_TMPDIR, as test failed"
  fi
}

setup_existing_provider() {
	cat << EOF > $BATS_TMPDIR/main.tf

provider "time" {}

resource "time_static" "test" {}

EOF
    # 'EOF' to escape $
    cat << 'EOF' > $BATS_TMPDIR/terragrunt.hcl

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
	cat << EOF > $BATS_TMPDIR/new_provider.tf

provider "$new_providers" {}

resource "random_id" "test" {
    byte_length = 8
}
EOF
}

setup_terragrunt_apply() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
    terragrunt init --terragrunt-working-dir "$BATS_TMPDIR" && terragrunt apply --terragrunt-working-dir "$BATS_TMPDIR" -auto-approve
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

    out=$(terragrunt graph-deps --terragrunt_working_dir "$BATS_TMPDIR")

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
		parse_tg_graph_deps "$BATS_TMPDIR" | jq -r '. | @csv' | query "$cfg_stack_sql"
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
