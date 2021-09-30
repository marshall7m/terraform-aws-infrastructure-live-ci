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

main() {

	set -e
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

	parse_args "$@"

	if [ -n "$random_defaults" ]; then
		staging_table="staging_$table"
		psql -c "DROP TABLE IF EXISTS $staging_table;"

		jq_to_psql_records "$items" "$staging_table"
		log "$staging_table:" "DEBUG"
		log "$(printf '\n%s' "$(psql -c "SELECT * FROM $staging_table")") " "DEBUG"

		log "Creating mock defaults triggers" "DEBUG"
		psql -f "$DIR/mock_sql/trigger_defaults.sql"

		log "Inserting $staging_table into $table" "DEBUG"
		psql -f "$DIR/mock_sql/insert_mock_records.sql"

		psql -t -c "insert_mock_records($staging_table, $table, $psql_cols, $count, $reset_identity_col, "${table}_defaults");"

		#WA: `psql -v bar=foo` giving syntax error for :bar within sql file -- using inline command as WA
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