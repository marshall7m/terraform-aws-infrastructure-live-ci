: '
- Mock order:
	- account dim
	- pr queue
	- commit queue
	- executions
'

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	count=0
	reset_identity_col=false
	while (( "$#" )); do
		case "$1" in
			--table)
				if [ -n "$2" ]; then
					table="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
			;;
			--items)
				if [ -n "$2" ]; then
					items="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
			;;
			--count)
				if [ -n "$2" ]; then
					# minus the input --items record
					count=$(($2 - 1))
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
			;;
			--random-defaults)
				random_defaults=true
				shift 1
			;;
			--update-parents)
				update_parents=true
				shift 1
			;;
			--return-jq-results)
				return_jq_results=true
				shift 1
			;;
			--reset-identity-col)
				reset_identity_col=true
				shift 1
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
	local rel_to="$2"

	log "Running terragrunt graph-dependencies on directory: $tg_dir" "INFO"
    out=$(terragrunt graph-dependencies --terragrunt-working-dir "$tg_dir")
    log "Terragrunt command out:" "DEBUG"
    log "$out" "DEBUG"

	parsed_stack=$(jq -n '{}')
    while read -r line; do
		parent=$( echo "$line" | grep -Po '"\K.+?(?="\s+\->)')
		dep=$( echo "$line" | grep -Po '\->\s+"\K.+(?=";)')

        if [ "$parent" != "" ]; then
			if [ -n "$rel_to" ]; then
				log "Transforming absolute paths to relative paths to: $rel_to" "DEBUG"
				parent=$(realpath -m --relative-to="$rel_to" "$parent")
				dep=$(realpath -m --relative-to="$rel_to" "$dep")
			fi
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
	local table=$2

	csv_table=$( echo "$jq_map" | jq -r '
		with_entries(if .value | type == "array" then .value |= "{" + join(", ") + "}" else . end) 
		| [values[]] | @csv
	')

	log "JQ mapping transformed to CSV strings" "DEBUG"
	log "$csv_table" "DEBUG"
	
	echo "$csv_table" | query -c "COPY $table FROM STDIN DELIMITER ',' CSV"
}

setup_mock_executions() {

	local records=$1

	jq_to_psql_records "$records" "staging_executions"

	query -c """
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
        
	FROM  (
		SELECT
			*,
			row_number() OVER () AS rn
		FROM
			staging_executions
	) mock_executions

	JOIN (
		SELECT
			*,
			row_number() OVER () AS rn
		FROM
			account_dim
		ORDER BY 
			RANDOM()
	) accounts
	ON
		(mock_executions.account_name = accounts.account_name)

	INNER JOIN (
		SELECT
			'run-' || substr(md5(random()::text), 0, 8) as execution_id,
			RANDOM() < 0.5 as is_rollback,
			(
				CASE (RANDOM() * .5)::INT
				WHEN 0 THEN 'success'
				WHEN 1 THEN 'failed'
				END
			) as status,
			'refs/heads/master^{' || substr(md5(random()::text), 0, 40) || '}' as base_source_version,
			'refs/pull/' || pr_id || '/head^{' || commit_id || '}' as head_source_version,
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
			'account-' || substr(md5(random()::text), 0, 5),
			account_path || '/' as account_path,
			ARRAY[NULL] as account_deps,
			random_between(1, 5),
			random_between(1, 5),
			ARRAY['voter-' || substr(md5(random()::text), 0, 5)]
			random_between(0, min_approval_count) as approval_count,
			random_between(1, 5) as min_approval_count,
			random_between(0, min_rejection_count) as rejection_count,
			random_between(1, 5) as min_rejection_count,
			row_number() OVER () AS rn
		FROM
			GENERATE_SERIES(1, '$mock_count') seq
	) defaults USING (rn);

	"""
}

setup_mock_staging_cfg_stack() {
	local account_dim=$1
	local git_root=$2

	log "Creating execution table based on local Terragrunt directory configurations" "INFO"

	query -c "CREATE TABLE mock_staging_cfg_stack (cfg_path VARCHAR PRIMARY KEY, cfg_deps text[], account_path VARCHAR);"
	
	cd "$git_root"
	while read account_path; do
		account_path=$(echo "$account_path" | tr -d '"')
		log "Account path: $account_path" "DEBUG"

		tg_deps_mapping=$(parse_tg_graph_deps "$account_path" "$git_root")
		
		log "Adding account_path as a foreign key to account_dim" "DEBUG"
		tg_deps_mapping=$(echo "$tg_deps_mapping" | jq --arg account_path $account_path '
		    to_entries | map_values(
				.cfg_path = .key
				| .cfg_deps = .value
				| .account_path = $account_path
				| del(.key)
				| del(.value)
			)
		')

		log "Terragrunt Dependency Mapping:" "DEBUG"
		log "$tg_deps_mapping" "DEBUG"
		
		jq_to_psql_records "$tg_deps_mapping" "mock_staging_cfg_stack"

	done <<< "$(echo "$account_dim" | jq 'map(.account_path)' | jq -c '.[]')"
}

setup_mock_account_dim() {
	local account_dim=$1

	query -c """
	CREATE OR REPLACE FUNCTION random_between(low INT, high INT) 
		RETURNS INT 
		LANGUAGE plpgsql AS
	\$\$
	BEGIN
		RETURN floor(random()* (high-low + 1) + low);
	END;
	\$\$;

	CREATE TABLE mock_staging_account_dim (
		account_name VARCHAR DEFAULT 'account-' || substr(md5(random()::text), 0, 5),
		account_path VARCHAR DEFAULT  'account-' || substr(md5(random()::text), 0, 5),
		account_deps TEXT[],
		min_approval_count INT DEFAULT random_between(1, 5),
		min_rejection_count INT DEFAULT random_between(1, 5),
		voters TEXT[] DEFAULT ARRAY['voter-' || substr(md5(random()::text), 0, 5)]
	)
	"""

	jq_to_psql_records "$account_dim" "mock_staging_account_dim"

	log "mock_staging_account_dim table:" "DEBUG"
	log "$(query -x "SELECT * FROM mock_staging_account_dim;")" "DEBUG"

	query -c """
	INSERT INTO account_dim (
		account_name,
		account_path,
		account_deps,
		min_approval_count,
		min_rejection_count,
		voters
	)

	SELECT
		*
	FROM
		mock_staging_account_dim;
	;
	"""
}


setup_mock_finished_status_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	
	query -c """

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

	SELECT DISTINCT ON (pr_id) pr_id,
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
	log "$(query -x "SELECT * FROM pr_queue;")" "DEBUG"

	log "commit_queue:" "DEBUG"
	log "$(query -x "SELECT * FROM commit_queue;")" "DEBUG"

	log "account_dim:" "DEBUG"
	log "$(query -x "SELECT * FROM account_dim;")" "DEBUG"

	log "executions:" "DEBUG"
	log "$(query -x "SELECT * FROM executions;")" "DEBUG"
}

drop_mock_temp_tables() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	query -c "DROP TABLE IF EXISTS mock_staging_account_stack, mock_staging_cfg_stack;"
}

table_exists() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local table=$1

	res=$(query -qtAX -c """
	SELECT EXISTS (
		SELECT 
			1 
		FROM 
			information_schema.tables 
		WHERE 
			table_schema = 'public' 
		AND 
			table_name = '$table'
	);
	""")

	log "results: $res" "DEBUG"

	if [ "$res" == 't' ]; then
		return 0
	else
		return 1
	fi
}

main() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

	parse_args "$@"

	if [ -n "$random_defaults" ]; then
		staging_table="staging_$table"
		jq_to_psql_records "$items" "$staging_table"
		log "$staging_table:" "DEBUG"
		log "$(printf '\n%s' "$(query -c "SELECT * FROM $staging_table")") " "DEBUG"

		log "Creating mock defaults triggers" "DEBUG"
		query -f "$DIR/mock_sql/trigger_defaults.sql"

		log "Inserting $staging_table into $table" "DEBUG"


		#WA: `psql -v bar=foo` giving syntax error for :bar within sql file using inline command as WA
		res=$(query -c """
		DO \$\$		
			DECLARE
				seq VARCHAR;	
			BEGIN
				IF $count > 0 THEN
					-- creates duplicate rows of '$staging_table' to match mock_count only if '$staging_table' contains one item
					INSERT INTO $staging_table
					SELECT s.* 
					FROM $staging_table s, GENERATE_SERIES(1, $count)
					WHERE (SELECT COUNT(*) FROM $staging_table) = 1;
				END IF;

				IF $reset_identity_col = true THEN
					seq := (SELECT pg_get_serial_sequence('$table', 'id'));
				
					PERFORM setval(seq, (SELECT COALESCE(MAX(id), 1) FROM $table));

					INSERT INTO $table (id, $psql_cols)
					SELECT
					nextval(seq),
					$psql_cols
					FROM $staging_table;
				ELSE
					INSERT INTO $table ($psql_cols)
					SELECT
					$psql_cols
					FROM $staging_table;
				END IF;
				
				ALTER TABLE $table DISABLE TRIGGER "$table"_default;  
				DROP TABLE $staging_table;
			END;
		\$\$ LANGUAGE plpgsql;
		""")

		echo "$res"
	else
		res=$(jq_to_psql_records "$items" "$table")
	fi

	if [ -n "$update_parents" ]; then
		log "Updating parent tables" "INFO"
		query -f "$DIR/mock_sql/mock_update_$(echo "$table")_parents.sql"
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi	