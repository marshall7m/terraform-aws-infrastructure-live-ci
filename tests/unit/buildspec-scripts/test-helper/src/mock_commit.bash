source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	head_ref="mock-commit-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
	commit_msg="mock modify tg paths"

	while (( "$#" )); do
		case "$1" in
			--commit-item)
				if [ -n "$2" ]; then
					commit_item="$2"
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--modify-items)
				if [ -n "$2" ]; then
					modify_items="$2"
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--abs-repo-dir)
			if [ -n "$2" ]; then
					abs_repo_dir="$2"
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--head-ref)
				if [ -n "$2" ]; then
					head_ref="$2"
					shift 2
				else
					log "Error: Argument for $1 is missing" "ERROR"
					exit 1
				fi
			;;
			--commit-msg)
				if [ -n "$2" ]; then
					commit_msg="$2"
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

modify_tg_path() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local tg_dir=$1
	local create_provider_resource=$2
	
	if [ -z "$tg_dir" ]; then
		log "\$1 for terragrunt directory is not set" "ERROR"
		exit 1
	fi
	
	# get terraform source dir from .terragrunt-cache/
	# tf_dir=$(terragrunt terragrunt-info --terragrunt-working-dir "$tg_dir" | jq '.WorkingDir' | tr -d '"') || exit 1
	#WA: use terragrunt dir instead of .terragrunt-cache for tf_dir since cache will be in .gitignore which leads to git not tracking cache changes
	# tradeoff being testing will be limited to terraform sources within cwd of terragrunt file
	#could workaround .gitignore and use different download source for tf module although that may risk .tfstate being exposed if more git involved test are included
	tf_dir="$tg_dir"
	
	log "Terraform dir: $tf_dir" "DEBUG"

	if [ "$create_provider_resource" == true ]; then
		log "Adding new provider resource" "INFO"
		res=$(create_resource "$tf_dir")
	else
		log "Adding random terraform output" "INFO"
		res=$(create_random_output "$tf_dir")
	fi

	echo "$res"
}

create_commit_changes() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local modify_items=$1
	local abs_repo_dir=$2

	res=$(jq -n '[]')
	while read item; do
		log "Path item:" "DEBUG"
		log "$(echo "$item" | jq '.')" "DEBUG"

		cfg_path=$(echo "$item" | jq -r '.cfg_path')
		create_provider_resource=$(echo "$item" | jq -r '.create_provider_resource // false')
		apply_changes=$(echo "$item" | jq -r '.apply_changes')

		modify_res=$(modify_tg_path "$abs_repo_dir/$cfg_path" "$create_provider_resource")

		item=$(echo "$item" | jq --arg modify_res "$modify_res" '
		($modify_res | fromjson) as $modify_res
		| . + $modify_res
		')

		log "Updated path item:" "DEBUG"
		log "$item" "DEBUG"

		res=$(echo "$res" | jq \
		--arg item "$item" '
		($item | fromjson) as $item
		| . + [$item]
		')

		if [ "$apply_changes" == true ]; then
			log "Applying mock changes" "INFO"
			terragrunt apply --terragrunt-working-dir $cfg_path -auto-approve > /dev/null 2> /dev/null || exit 1
		fi
	done <<< "$(echo "$modify_items" | jq -c '.[]')"

	echo "$res"
}

add_commit_to_queue() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	commit_item=$1
	commit_msg=$2

	log "Adding testing changes to branch: $(git rev-parse --abbrev-ref HEAD)" "INFO"

	if [ $(git status --short | wc -l) == 0 ]; then
		log "Nothing to commit -- creating dummy file to allow git to create a new commit" "DEBUG"
		touch dummy.txt
	fi

	log "commit msg: $commit_msg" "DEBUG"
	git add "$(git rev-parse --show-toplevel)/"
	git commit -m "$commit_msg"

	commit_id=$(git log --pretty=format:'%H' -n 1)

	commit_item=$(echo "$commit_item" | jq \
	--arg commit_id "$commit_id" '
		{"commit_id": $commit_id} + .
	')

	log "Adding commit ID to queue: $commit_id" "DEBUG"
	
	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"
	commit_item=$("$DIR/mock_tables.bash" \
		--table "commit_queue" \
		--items "$commit_item" \
		--enable-defaults \
		--update-parents \
	| jq '.[0]')
	
	log "Inserted commit record: " "DEBUG"
	log "$commit_item" "DEBUG"
}

create_resource() {
	local tf_dir=$1

	testing_id=$(openssl rand -base64 10 | tr -dc A-Za-z0-9)

	null_content=$(cat << EOM
provider "null" {}

resource "null_resource" "this" {}
EOM
	)

	random_content=$(cat << EOM
provider "random" {}

resource "random_id" "this" {
	byte_length = 8
}
EOM
	)

	testing_providers_data=$(jq -n \
	--arg random_content "$random_content" \
	--arg null_content "$null_content" '
	[
		{
			"address": "registry.terraform.io/hashicorp/random",
			"content": $random_content,
			"resource_spec": "random_id.this"
		},
		{
			"address": "registry.terraform.io/hashicorp/null",
			"content": $null_content,
			"resource_spec": "null_resource.this"
		}
	]
	')

	log "Getting Terragrunt file providers" "INFO"
	cfg_providers=$(terragrunt providers --terragrunt-working-dir $tf_dir 2> /dev/null | grep -oP '─\sprovider\[\K.+(?=\])' | sort -u)
	log "Providers: $(printf "\n%s" "${cfg_providers[@]}")" "DEBUG"

	file_path="$tf_dir/$testing_id.tf"

	log "Getting a testing provider that is not in the terraform directory" "INFO"
	target_testing_provider=$(echo "$testing_providers_data" | jq \
	--arg cfg_providers "${cfg_providers[*]}" \
	--arg file_path "$file_path" '
	(try ($cfg_providers | split(" ")) // []) as $cfg_providers
	| (map(select(.name | IN($cfg_providers[]) | not))[0]) as $target
	| $target + {"file_path": $file_path, "type": "provider"}
	')

	#convert jq to formatted content and remove escape characters
	content=$(echo "$target_testing_provider" | jq '.content' | sed -e 's/^.//' -e 's/.$//')
	content=$(echo -e "$content" | tr -d '\')

	log "Adding mock resource content to $file_path:" "DEBUG"

	log "$content" "DEBUG"
	echo "$content" > "$file_path"

	echo "$target_testing_provider" 
}

create_random_output() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local tf_dir=$1
	id=$(openssl rand -base64 10 | tr -dc A-Za-z0-9)
	file_path="$tf_dir/$id.tf"
	log "Filepath: $file_path" "DEBUG"

	resource_name="test_file_$id"
	resource_spec="output.$resource_name"
	value="test"

	cat << EOF > "$file_path"
output "$resource_name" {
	value = "$value"
}
EOF

	jq -n \
	--arg resource_spec "$resource_spec" \
	--arg value "$value" \
	--arg file_path "$file_path" '
	{
		"type": "output",
		"resource_spec": $resource_spec,
		"value": $value,
		"file_path": $file_path
	}'
}


main() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	parse_args "$@"
	
	log "Creating testing branch: $head_ref" "INFO"
	cd "$abs_repo_dir" && git checkout -B "$head_ref" > /dev/null

	if [ -n "$modify_items" ]; then
		log "Creating changes within $head_ref" "INFO"
		modify_items=$(create_commit_changes "$modify_items" "$abs_repo_dir")
	fi

	log "Committing changes and adding commit to queue" "INFO"
	add_commit_to_queue "$commit_item" "$commit_msg" > /dev/null

	log "Switching back to default branch" "DEBUG"
    cd "$abs_repo_dir" && git checkout "$(git remote show $(git remote) | sed -n '/HEAD branch/s/.*: //p')" > /dev/null

	log "modify_items" "DEBUG"
	log "$modify_items" "DEBUG"

	jq -n --arg commit_item "$commit_item" --arg modify_items "$modify_items" '
		($commit_item | try fromjson // {}) as $commit_item
		| ($modify_items | try fromjson // []) as $modify_items
		| $commit_item + {"modify_items": $modify_items}
	'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi