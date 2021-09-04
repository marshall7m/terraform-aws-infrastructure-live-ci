parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	while (( "$#" )); do
		case "$1" in
			--based-on-tg-dir)
				if [ -n "$2" ]; then
					tg_dir="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--account-stack)
				if [ -n "$2" ]; then
					account_stack=$( echo "$2" | jq '. | tojson')
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--running-pr-id)
				if [ -n "$2" ]; then
					running_pr_id="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--running-commit-id)
				if [ -n "$2" ]; then
					running_commit_id="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--running-execution-id)
				if [ -n "$2" ]; then
					running_execution_id="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--running-rollback)
				is_rollback=true
				;;
			--finished-count)
				if [ -n "$2" ]; then
					finished_count="$2"
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

parse_tg_graph_deps() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local tg_dir="$1"

	log "Running terragrunt graph-dependencies on directory: $tg_dir" "INFO"
    out=$(terragrunt graph-dependencies --terragrunt_working_dir "$tg_dir")
    log "Terragrunt command out:" "DEBUG"
    log "$out" "DEBUG"

	parsed_stack=$(jq -n '{}')
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

jq_map_to_psql_table() {
	local jq_map=$1
	local key_column=$2
	local value_column=$3
	local table=$4

	echo "$jq_map" | jq -r \
	--arg key_column $key_column \
	--arg value_column $value_column '
		fromjson 
		| to_entries
		| map(
			with_entries(
				(if .key == "key" then .key |= $key_column
				elif .key == "value" then .key |= $value_column else . end) |
				(if .value | type == "array" then .value |= "{" + join(", ") + "}" else . end)
			)
		) | .[] | [.[$key_column], .[$value_column]] | @csv
	' | query """
	COPY $table ($key_column, $value_column) FROM STDIN DELIMITER ',' CSV
	"""
}


setup_mock_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	parse_args "$@"
	
	if [ -n "$tg_dir" ]; then
		if [ -z "$account_stack" ]; then
			log "--account-stack is not set - Required if --based-on-tg-dir is set" "ERROR"
			exit 1
		fi

		log "Creating execution table based on local Terragrunt directory configurations" "INFO"
		query "CREATE TABLE staging_cfg_stack (cfg_path VARCHAR, cfg_deps text[]);"
		jq_map_to_psql_table "$(parse_tg_graph_deps "$tf_dir")" "cfg_path" "cfg_deps" "staging_cfg_stack"
		log "Staging config stack table:" "DEBUG"
		log "$(query "SELECT * FROM staging_cfg_stack;")" "DEBUG"

		log "Using user-defined account stack for account_dim table" "INFO"
		query "CREATE TABLE staging_account_stack (account_path VARCHAR, account_deps text[]);"
		jq_map_to_psql_table "$account_stack" "account_path" "account_deps" "staging_account_stack"
		log "Staging account stack table:" "DEBUG"
		log "$(query "SELECT * FROM staging_account_stack;")" "DEBUG"
	fi

	
	query """

	CREATE OR REPLACE FUNCTION random_between(low INT, high INT) 
		RETURNS INT 
		LANGUAGE plpgsql AS
	\$\$
	BEGIN
		RETURN floor(random()* (high-low + 1) + low);
	END;
	\$\$;

	INSERT INTO account_dim (
		account_name,
		account_path,
		account_deps,
		min_approval_count,
		min_rejection_count,
		voters
	)

	SELECT
		'account-' || substr(md5(random()::text), 0, 5),
		account_path,
		account_deps,
		random_between(1, 5),
		random_between(1, 5),
		'[' || 'voter-' || substr(md5(random()::text), 0, 5) || ']'
	FROM
		staging_account_stack;
	;

	INSERT INTO pr_queue (
		pr_id,
		status,
		base_ref,
		head_ref
	)

	SELECT
		DISTINCT ON (pr_id) pr_id,
		status,
		base_ref,
		head_ref
	FROM (
		SELECT 
			random_between(1, 10) as pr_id,
			(
				CASE (RANDOM() < .5)::INT
				WHEN 0 THEN 'failed'
				WHEN 1 THEN 'success'
				END
			) as status,
			'master' as base_ref,
			'feature-' || seq as head_ref
		FROM GENERATE_SERIES(1, 10) seq
	) AS sub
	ORDER BY 
		pr_id
	;

	INSERT INTO commit_queue (
		commit_id,
		pr_id,
		status,
		is_rollback
	)

	SELECT 
		substr(md5(random()::text), 0, 16) as commit_id,
		(SELECT pr.pr_id FROM pr_queue pr ORDER BY RANDOM()+id LIMIT 1),
		(
            CASE (RANDOM() < .05)::INT
            WHEN 0 THEN 'failed'
			WHEN 1 THEN 'success'
            END
        ) as status,
		random() < 0.5 as is_rollback
	FROM GENERATE_SERIES(1, 30) seq;
	"""

	foo="""	
	
	
	
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

	log "pr_queue:" "DEBUG"
	log "$(query "SELECT * FROM pr_queue;")" "DEBUG"

	log "commit_queue:" "DEBUG"
	log "$(query "SELECT * FROM commit_queue;")" "DEBUG"

	log "account_dim:" "DEBUG"
	log "$(query "SELECT * FROM account_dim;")" "DEBUG"

	log "executions:" "DEBUG"
	log "$(query "SELECT * FROM executions;")" "DEBUG"
}

drop_mock_temp_tables() {
	query "DROP TABLE IF EXISTS staging_account_stack, staging_cfg_stack;"
}
