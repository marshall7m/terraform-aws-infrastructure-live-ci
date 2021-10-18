source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"
export PATH="$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/psql-utils/src:$PATH"

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	reset_identity_col=false
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

	if [ -n "$enable_defaults" ]; then
		log "Enabling default trigger for table: $table" "INFO"
		psql -q -f "$DIR/mock_sql/trigger_defaults.sql"
		psql -q -c "ALTER TABLE $table ENABLE TRIGGER ${table}_default"
	fi

	if [ -n "$count" ]; then
		log "Generating $count copies of item into jq array" "INFO"
		items=$(echo "$items" | jq --arg count "$count" '
		if (. | type) == "object" then
			[(. | fromjson)] as $items
			| [range($count)] | .[] 
			| $items += $items[-1] 
		else 
			error("--mock-count is not available with array item") 
		end')
	fi

	log "Inserting mock records to $table" "INFO"
	if [ -n "$results_out_dir" ]; then
		mock_output="$results_out_dir/mock_records.json"
		log "Storing mock results within: $mock_output" "INFO" 
		jq_to_psql_records.bash --jq-input "$items" --table "$table" ${type_map:+--type-map "$type_map"} > "$mock_output" || exit 1
	else
		mock_output=$(jq_to_psql_records.bash --jq-input "$items" --table "$table" ${type_map:+--type-map "$type_map"})
	fi

	if [ -n "$enable_defaults" ]; then
		log "Disabling default trigger for table: $table" "INFO"
		psql -q -c "ALTER TABLE $table DISABLE TRIGGER ${table}_default"
	fi

	if [ -n "$update_parents" ]; then
		log "Updating parent tables" "INFO"
		psql -qt -f "$DIR/mock_sql/mock_update_${table}_parents.sql"
	fi

	echo "$mock_output"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi