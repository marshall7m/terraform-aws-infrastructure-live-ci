
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