source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"
source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/psql-utils/load.bash"

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

setup_mock_staging_cfg_stack() {
	local account_dim=$1
	local git_root=$2

	log "Creating execution table based on local Terragrunt directory configurations" "INFO"

	psql -c "CREATE TABLE mock_staging_cfg_stack (cfg_path VARCHAR PRIMARY KEY, cfg_deps text[], account_path VARCHAR);"
	
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

main() {

	set -e
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

	parse_args "$@"

	if [ -n "$random_defaults" ]; then
		staging_table="staging_$table"
		jq_to_psql_records "$items" "$staging_table"
		log "$staging_table:" "DEBUG"
		log "$(printf '\n%s' "$(psql -c "SELECT * FROM $staging_table")") " "DEBUG"

		log "Creating mock defaults triggers" "DEBUG"
		psql -f "$DIR/mock_sql/trigger_defaults.sql"

		log "Inserting $staging_table into $table" "DEBUG"


		#WA: `psql -v bar=foo` giving syntax error for :bar within sql file -- using inline command as WA
		psql -t -c """
		DO \$\$		
			DECLARE
				seq VARCHAR;
			BEGIN
				ALTER TABLE $table ENABLE TRIGGER "$table"_default;
				IF $count > 0 THEN
					-- creates duplicate rows of '$staging_table' to match mock_count only if '$staging_table' contains one item
					INSERT INTO $staging_table
					SELECT s.* 
					FROM $staging_table s, GENERATE_SERIES(1, $count)
					WHERE (SELECT COUNT(*) FROM $staging_table) = 1;
				END IF;

				IF $reset_identity_col = true THEN
					SELECT pg_get_serial_sequence('$table', 'id') INTO seq;

					PERFORM setval(seq, COALESCE(max(id) + 1, 1), false) FROM $table;

					INSERT INTO $table (id, $psql_cols)
					SELECT
					nextval(seq),
					$psql_cols
					FROM $staging_table;
				ELSE
					INSERT INTO $table ($psql_cols)
					SELECT $psql_cols
					FROM $staging_table;
				END IF;
				
				ALTER TABLE $table DISABLE TRIGGER "$table"_default;  
				DROP TABLE $staging_table;
			END;
		\$\$ LANGUAGE plpgsql;
		"""
	else
		jq_to_psql_records "$items" "$table"
	fi

	if [ -n "$update_parents" ]; then
		log "Updating parent tables" "INFO"
		psql -f "$DIR/mock_sql/mock_update_$(echo "$table")_parents.sql"
	fi

	set +e 
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi