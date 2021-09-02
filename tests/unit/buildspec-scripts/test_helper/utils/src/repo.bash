#!/bin/bash
setup_test_file_repo() {
	local clone_url=$1

	export BATS_FILE_TMPDIR=$(mktemp -d)
	log "BATS_FILE_TMPDIR: $BATS_FILE_TMPDIR" "DEBUG"

	log "Cloning Github repo to test file's shared tmp directory" "INFO"
	clone_testing_repo $clone_url $BATS_FILE_TMPDIR
}

setup_test_case_repo() {
	export TEST_CASE_REPO_DIR="$BATS_TEST_TMPDIR/test-repo"
	log "Cloning local template Github repo to test case tmp dir: $TEST_CASE_REPO_DIR" "INFO"
	clone_testing_repo $BATS_FILE_TMPDIR $TEST_CASE_REPO_DIR
	cd "$TEST_CASE_REPO_DIR"
}

create_testing_repo_mock_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	# create mock executions/accounts/commits tables with finished status
}

parse_tg_path_args() {
	while (( "$#" )); do
		case "$1" in
			--path)
				if [ -n "$2" ]; then
					tg_dir=$1
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
			;;
			--new_provider_resource)
				new_provider_resource=true
			;;
		esac
	done
}

setup_test_case_branch() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	export TESTING_HEAD_REF="test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
	
	log "Creating testing branch: $TESTING_HEAD_REF" "INFO"
	git checkout -B "$TESTING_HEAD_REF"
}

modify_tg_path() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	parse_tg_path_args

	# get terraform source dir from .terragrunt-cache/
	tf_dir=$(terragrunt terragrunt-info --terragrunt_working_dir "$tg_dir" \
		| jq '.WorkingDir'
	)
	
	if [ -n "$new_provider_resource" ]; then
		log "Adding new provider resource" "INFO"
		create_new_provider_resource "$tf_dir"
	else
		log "Adding random terraform output" "INFO"
		create_random_output "$tf_dir"
	fi
}

setup_test_case_commit() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	if [ -z "$TEST_CASE_REPO_DIR" ]; then
		log "Test case repo directory was not set" "ERROR"
		exit 1
	else
		cd "$TEST_CASE_REPO_DIR"
	fi

	log "Adding testing changes to branch: $(git rev-parse --abbrev-ref HEAD)" "INFO"
	git add "$(git rev-parse --show-toplevel)/"
	
	git commit -m $TESTING_HEAD_REF
	export TESTING_COMMIT_ID=$(git log --pretty=format:'%h' -n 1)

	log "Adding testing commit to queue" "INFO"
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

	# log "Checking out commit before testing commit" "INFO"
	# git checkout $(git rev-parse `git branch -r --sort=committerdate | tail -1`)
}

teardown_tmp_dir() {
  if [ $BATS_TEST_COMPLETED ]; then
    rm -rf $BATS_TEST_TMPDIR
  else
    echo "Did not delete $BATS_TEST_TMPDIR, as test failed"
  fi
}

create_new_provider_resource() {
	local tf_dir=$1

	testing_id=$(openssl rand -base64 10 | tr -dc A-Za-z0-9)

	declare -A testing_providers
	testing_providers["registry.terraform.io/hashicorp/null"]=$(cat << EOM
	provider "null" {}

	resource "null_resource" "test_$testing_id" {}
EOM
	)
	testing_providers["registry.terraform.io/hashicorp/random"]=$(cat << EOM
	provider "random" {}

	resource "random_id" "test_$testing_id" {
		byte_length = 8
	}
EOM
	)

	log "Getting Terragrunt file providers" "INFO"
	cfg_providers=$(terragrunt providers --terragrunt-working-dir $tf_dir 2>/dev/null | grep -oP '─\sprovider\[\K.+(?=\])' | sort -u)
	log "Providers: $(printf "\n%s" "${cfg_providers[@]}")" "DEBUG"

	log "Getting testing provider that's not in $tf_dir" "INFO"
	for provider in "${!testing_providers[@]}"; do
		if [[ ! " ${cfg_providers[@]} " =~ " ${provider} " ]]; then
			log "Testing Provider: $provider" "DEBUG"
			log "Adding config:" "DEBUG"
			cfg="${testing_providers[$provider]}"
			log "$cfg" "DEBUG"
			echo "$cfg" > "$tf_dir/$testing_id.tf"
			exit 0
		fi
	done
}

create_random_output() {
	local tf_dir=$1

	cat << EOF > $tf_dir/$(openssl rand -base64 10 | tr -dc A-Za-z0-9).tf
output "test_case_$BATS_TEST_NUMBER" {
			value = "test"
		}
EOF
}

setup_terragrunt_apply() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
    terragrunt init --terragrunt-working-dir "$BATS_TEST_TMPDIR" && terragrunt apply --terragrunt-working-dir "$BATS_TEST_TMPDIR" -auto-approve
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

    out=$(terragrunt graph-deps --terragrunt_working_dir "$BATS_TEST_TMPDIR")

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
		parse_tg_graph_deps "$BATS_TEST_TMPDIR" | jq -r '. | @csv' | query "$cfg_stack_sql"
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
