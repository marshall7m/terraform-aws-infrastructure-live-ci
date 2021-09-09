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
					account_stack=$( echo "$2" | jq '. | tojson | fromjson') || \
					(log "account stack should be a jq mapping with account paths relative to git repo root (e.g. {\"dev-account/\": [\"security-account/\"})" "ERROR" \
					&& exit 1)
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
		dep=$( echo "$line" | grep -Po '\->\s+"\K.+(?=";)')

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
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local jq_map=$1
	local key_column=$2
	local value_column=$3
	local table=$4

	csv_table=$( echo "$jq_map" | jq -r \
	--arg key_column $key_column \
	--arg value_column $value_column '
		to_entries
		| map(
			with_entries(
				(if .key == "key" then .key |= $key_column
				elif .key == "value" then .key |= $value_column else . end) |
				(if .value | type == "array" then .value |= "{" + join(", ") + "}" else . end)
			)
		) | .[] | [.[$key_column], .[$value_column]] | @csv
	')

	log "JQ mapping transformed to CSV strings" "DEBUG"
	log "$csv_table" "DEBUG"
	
	echo "$csv_table" | query """
	COPY $table ($key_column, $value_column) FROM STDIN DELIMITER ',' CSV
	"""
}


setup_mock_finished_status_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	parse_args "$@"
	
	if [ -n "$tg_dir" ]; then
		if [ -z "$account_stack" ]; then
			log "--account-stack is not set - Required if --based-on-tg-dir is set" "ERROR"
			exit 1
		fi

		log "Creating execution table based on local Terragrunt directory configurations" "INFO"
		query "CREATE TABLE mock_staging_cfg_stack (cfg_path VARCHAR, cfg_deps text[]);"
		tg_deps_mapping=$(parse_tg_graph_deps "$tf_dir")
		log "Terragrunt Dependency Mapping:" "DEBUG"
		log "$tg_deps_mapping" "DEBUG"
		jq_map_to_psql_table "$tg_deps_mapping" "cfg_path" "cfg_deps" "mock_staging_cfg_stack"
		log "Staging config stack table:" "DEBUG"
		log "$(query --psql-extra-args "-x" "SELECT * FROM mock_staging_cfg_stack;")" "DEBUG"

		log "Using user-defined account stack for account_dim table" "INFO"
		query "CREATE TABLE mock_staging_account_stack (account_path VARCHAR, account_deps text[]);"
		jq_map_to_psql_table "$account_stack" "account_path" "account_deps" "mock_staging_account_stack"
		log "Staging account stack table:" "DEBUG"
		log "$(query --psql-extra-args "-x" "SELECT * FROM mock_staging_account_stack;")" "DEBUG"
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
		ARRAY['voter-' || substr(md5(random()::text), 0, 5)]
	FROM
		mock_staging_account_stack;
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
				CASE (RANDOM() < 0.5)::INT
				WHEN 0 THEN 'failed'
				WHEN 1 THEN 'success'
				END
			) as status,
			'master' as base_ref,
			'feature-' || seq as head_ref
		FROM GENERATE_SERIES(1, 10) seq
	) AS sub
	;

	INSERT INTO commit_queue (
		commit_id,
		pr_id,
		status,
		is_rollback
	)

	SELECT 
		commit_id,
		pr_id,
		status,
		is_rollback
	FROM   (
		SELECT 
			substr(md5(random()::text), 0, 40) as commit_id,
			(
				CASE (RANDOM() < 0.5)::INT
				WHEN 
					0 THEN 'failed'
				WHEN 
					1 THEN 'success'
				END
			) as status,
			random() < 0.5 as is_rollback,
			row_number() OVER () AS rn
		FROM 
			GENERATE_SERIES(1, 30) seq
	) commit

	JOIN   (
		SELECT 
			pr_id, 
			row_number() OVER () AS rn
		FROM 
			pr_queue
		ORDER BY 
			RANDOM()
		LIMIT 
			30
	) pr USING (rn)
	;

	INSERT INTO executions (
		execution_id,
        pr_id,
        commit_id,
		base_source_version,
		head_source_version,
        is_rollback,
        cfg_path,
		cfg_deps,
        account_deps,
        status,
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
        execution_id,
        pr_id,
        commit_id,
		'refs/heads/master^{' || substr(md5(random()::text), 0, 40) || '}' as base_source_version,
		'refs/pull/' || pr_id || '/head^{' || commit_id || '}' as head_source_version,
        is_rollback,
        cfg_path,
		cfg_deps,
        account_deps,
        status,
        'terragrunt plan ' || '--terragrunt-working-dir ' || cfg_path as plan_command,
		'terragrunt apply ' || '--terragrunt-working-dir ' || cfg_path || ' -auto-approve' as deploy_command,
        (
			CASE
				WHEN 
					is_rollback = false THEN ARRAY[NULL]
				WHEN 
					is_rollback = true THEN ARRAY['provider/' || substr(md5(random()::text), 0, 5)]
			END
		) as new_providers, 
		(
			CASE
				WHEN 
					is_rollback = false THEN ARRAY[NULL]
				WHEN 
					is_rollback = true THEN ARRAY['resource.' || substr(md5(random()::text), 0, 5)]
			END
		) as new_resources,
        account_name,
        account_path,
        voters,
        approval_count,
        min_approval_count,
        rejection_count,
        min_rejection_count
        
	FROM  (
		SELECT
			'run-' || substr(md5(random()::text), 0, 8) as execution_id,
			RANDOM() < 0.5 as is_rollback,
			(
				CASE (RANDOM() * .5)::INT
				WHEN 0 THEN 'success'
				WHEN 1 THEN 'failed'
				END
			) as status,
			row_number() OVER () AS rn
		FROM
			GENERATE_SERIES(1, 50) seq
	) random_executions

	JOIN (
		SELECT 
			cfg_path as cfg_path,
			cfg_deps as cfg_deps,
			row_number() OVER () AS rn
		FROM 
			mock_staging_cfg_stack
		ORDER BY 
			RANDOM()
		LIMIT 50
	) deps USING (rn)

	JOIN (
		SELECT
			account_name,
			account_path,
			account_deps,
			voters,
			random_between(0, min_approval_count) as approval_count,
			min_approval_count,
			random_between(0, min_approval_count) as rejection_count,
			min_rejection_count,
			row_number() OVER () AS rn
		FROM
			account_dim
		ORDER BY 
			RANDOM()
		LIMIT 50
	) accounts USING (rn)

	JOIN   (
		SELECT 
			pr_id,
			commit_id,
			row_number() OVER () AS rn
		FROM 
			commit_queue
		ORDER BY 
			RANDOM()
		LIMIT 
			50
	) commit USING (rn);

	
	"""

	log "pr_queue:" "DEBUG"
	log "$(query --psql-extra-args "-x" "SELECT * FROM pr_queue;")" "DEBUG"

	log "commit_queue:" "DEBUG"
	log "$(query --psql-extra-args "-x" "SELECT * FROM commit_queue;")" "DEBUG"

	log "account_dim:" "DEBUG"
	log "$(query --psql-extra-args "-x" "SELECT * FROM account_dim;")" "DEBUG"

	log "executions:" "DEBUG"
	log "$(query --psql-extra-args "-x" "SELECT * FROM executions;")" "DEBUG"
}

drop_mock_temp_tables() {
	query "DROP TABLE IF EXISTS mock_staging_account_stack, mock_staging_cfg_stack;"
}
