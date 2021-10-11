source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"
export PATH="$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/psql-utils/src:$PATH"

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
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--items)
				if [ -n "$2" ]; then
					items="$2"
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--count)
				if [ -n "$2" ]; then
					# minus the input --items record
					count=$(($2 - 1))
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--enable-defaults)
				enable_defaults=true
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
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--type-map)
				if [ -n "$2" ]; then
					type_map="$2"
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			*)
				log "Unknown Option: $1" "ERROR"
				exit 1
			;;
		esac
	done
}

main() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

	parse_args "$@"

	mock_filepath="$results_out_dir/mock_results.json"
	if [ -n "$enable_defaults" ]; then
		log "Enabling table's associated default triggers" "INFO"

		staging_table="staging_$table"

		psql -c "DROP TABLE IF EXISTS $staging_table;" > /dev/null

		if [ -n "$type_map" ]; then
			jq_to_psql_records.bash --jq-input "$items" --table "$staging_table" --type-map "$type_map" > /dev/null || exit 1 
		else
			jq_to_psql_records.bash --jq-input "$items" --table "$staging_table" > /dev/null || exit 1
		fi
		log "$staging_table:" "DEBUG"
		log "$(printf '\n%s' "$(psql -x -c "SELECT * FROM $staging_table")") " "DEBUG"

		log "Creating mock defaults triggers" "DEBUG"
		psql -f "$DIR/mock_sql/trigger_defaults.sql" > /dev/null

		log "Inserting $staging_table into $table" "DEBUG"
		psql -f "$DIR/mock_sql/insert_mock_records.sql" > /dev/null

		if [ -n "$results_to_json" ]; then
			log "Storing mock results within: $mock_filepath" "INFO" 
			psql -t -o "$mock_filepath" \
				-c "SELECT insert_mock_records('$staging_table', '$table', '$psql_cols', $count, $reset_identity_col, '"${table}_default"');" > /dev/null
			res=$(jq -n --arg mock_filepath "$mock_filepath" '{"mock_filepath": $mock_filepath}')
		else
			psql -c "SELECT insert_mock_records('$staging_table', '$table', '$psql_cols', $count, $reset_identity_col, '"${table}_default"');" > /dev/null
		fi
		psql -c "DROP TABLE IF EXISTS $staging_table;" > /dev/null
	else
		if [ -n "$results_to_json" ]; then
			log "Storing mock results within: $mock_filepath" "INFO" 

			if [ -n "$type_map" ]; then
				jq_to_psql_records.bash --jq-input "$items" --table "$staging_table" --type-map "$type_map" > "$mock_filepath" || exit 1
			else
				jq_to_psql_records.bash --jq-input "$items" --table "$staging_table" > "$mock_filepath" || exit 1
			fi

			res=$(jq -n --arg mock_filepath "$mock_filepath" '{"mock_filepath": $mock_filepath}')
		else
			jq_to_psql_records.bash --jq-input "$items" --table "$table" --type-map "$type_map" > /dev/null
		fi
	fi

	if [ -n "$update_parents" ]; then
		log "Updating parent tables" "INFO"
		if [ -n "$results_to_json" ]; then
			update_filepath="$results_out_dir/mock_update_${table}_parents.json"
			log "Storing mock results within: $update_filepath" "INFO"
			
			psql -t -f "$DIR/mock_sql/mock_update_${table}_parents.sql" -o "$update_filepath"

			res=$(echo "$res" | jq --arg update_filepath "$update_filepath" '{"update_filepath": $update_filepath}')
		else
			psql -f "$DIR/mock_sql/mock_update_${table}_parents.sql"
		fi
	fi

	echo "$res"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi