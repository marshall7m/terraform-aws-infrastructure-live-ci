parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	while (( "$#" )); do
		case "$1" in
			--account-stack)
				if [ -n "$2" ]; then
					account_stack=$( echo "$2" | jq '. | tojson')
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--pr-count)
				if [ -n "$2" ]; then
					pr_count="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--commit-count)
				if [ -n "$2" ]; then
					commit_count="$2"
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

create_mock_tables() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
	#TODO: Set up random table records that have finished statuses
}