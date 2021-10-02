source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"
source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/psql-utils/load.bash"

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	count=0
	reset_identity_col=false
	results_out_dir="$PWD"
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
			--results-to-json)
				results_to_json=true
				shift 1
			;;
			--results-out-dir)
				if [ -n "$2" ]; then
					# minus the input --items record
					results_out_dir="$2"
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

main() {
	set -e
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

	parse_args "$@"

	mock_filepath="$results_out_dir/mock_results.json"
	if [ -n "$random_defaults" ]; then
		staging_table="staging_$table"
		psql -c "DROP TABLE IF EXISTS $staging_table;" > /dev/null

		jq_to_psql_records "$items" "$staging_table" > /dev/null
		log "$staging_table:" "DEBUG"
		log "$(printf '\n%s' "$(psql -c "SELECT * FROM $staging_table")") " "DEBUG"

		log "Creating mock defaults triggers" "DEBUG"
		psql -f "$DIR/mock_sql/trigger_defaults.sql" > /dev/null

		log "Inserting $staging_table into $table" "DEBUG"
		psql -f "$DIR/mock_sql/insert_mock_records.sql" > /dev/null

		if [ -n "$results_to_json" ]; then
			log "Storing mock results within: $mock_filepath" "INFO" 
			psql -t -c "SELECT insert_mock_records('$staging_table', '$table', '$psql_cols', $count, $reset_identity_col, '"${table}_default"');" -o "$mock_filepath"
			log "adding response" "DEBUG"
			res=$(jq -n --arg mock_filepath "$mock_filepath" '{"mock_filepath": $mock_filepath}')
		else
			psql -c "SELECT insert_mock_records('$staging_table', '$table', '$psql_cols', $count, $reset_identity_col, '"${table}_default"');"
		fi
		psql -c "DROP TABLE IF EXISTS $staging_table;" > /dev/null
	else
		jq_to_psql_records "$items" "$table" > "$mock_filepath"
		res=$(jq -n --arg mock_filepath "$mock_filepath" '{"mock_filepath": $mock_filepath}')
	fi

	if [ -n "$update_parents" ]; then
		for update_file in "$DIR/mock_sql/mock_update_${table}_parents/*.sql"; do
			if [ -n "$results_to_json" ]; then
				update_filepaths="$results_out_dir/$update_dir/${update_file}_results.json"
				log "Storing mock results within: $update_filepaths" "INFO"
				update_dir=$(dirname "$update_file" | xargs -I {} basename {})
				log "Updating parent tables" "INFO"
				psql -t -f "$DIR/mock_sql/mock_update_${table}_parents.sql" -o "$update_filepaths"

				res=$(echo "$res" | jq --arg update_filepaths "$update_filepaths" '.update_filepaths |= . + [$update_filepaths]')
			else
				log "Updating parent tables" "INFO"
				psql -f "$DIR/mock_sql/mock_update_${table}_parents.sql"
			fi
		done
	fi

	echo "$res"

	set +e 
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi