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
	local new_provider_resource=$2
	
	# get terraform source dir from .terragrunt-cache/
	tf_dir=$(terragrunt terragrunt-info --terragrunt-working-dir "$tg_dir" | jq '.WorkingDir' | tr -d '"')
	
	log "Terraform dir: $tf_dir" "DEBUG"

	if [ -n "$new_provider_resource" ]; then
		log "Adding new provider resource" "INFO"
		create_new_provider_resource "$tf_dir"
	else
		log "Adding random terraform output" "INFO"
		create_random_output "$tf_dir"
	fi
}

create_commit_changes() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local modify_items=$1
	
	for (( idx=0; idx<=$(echo "$modify_items" | jq '. | length'); idx+=1 )); do
		cfg_path=$(echo "$modify_items" | jq --arg idx $idx '.[($idx | tonumber)].cfg_path' | tr -d '"')
		new_provider_resource=$(echo "$modify_items" | jq --arg idx $idx '.[($idx | tonumber)].new_provider_resource' | tr -d '"')
		apply_changes=$(echo "$modify_items" | jq --arg idx $idx '.[($idx | tonumber)].apply_changes' | tr -d '"')

		res=$(modify_tg_path "$cfg_path" "$new_provider_resource")
		mock_provider=$(echo "$res" | jq 'keys')
		mock_resource=$(echo "$res" | jq '.resource')

		if [ -n "$apply_changes" ]; then
			terragrunt apply --terragrunt-working-dir $cfg_path -auto-approve >/dev/null
		fi

		modify_items=$(echo "$modify_items" | jq \
		--arg idx $idx \
		--arg mock_provider $mock_provider \
		--arg mock_resource $mock_resource '
		($idx | tonumber) as $idx
		| .[$idx].new_providers = $mock_provider | .[$idx].new_resources = $mock_resource
		')
	done
}

add_commit_to_queue() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local commit_item=$1
	local commit_msg=$2

	log "Adding testing changes to branch: $(git rev-parse --abbrev-ref HEAD)" "INFO"

	if [ $(git status --short | wc -l) == 0 ]; then
		log "Nothing to commit -- creating dummy file to allow git to create a new commit" "DEBUG"
		touch dummy.txt
	fi

	git add "$(git rev-parse --show-toplevel)/"
	git commit -m "$commit_msg"

	commit_id=$(git log --pretty=format:'%H' -n 1)

	log "Adding commit ID to queue: $commit_id" "DEBUG"

	commit_items=$(echo "$commit_item" | jq -n \
	--arg commit_id $commit_id '
		{"commit_id": $commit_id} + .
	')

	DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"
	"$DIR/mock_tables.bash" --tables "commit_queue" --items "$commit_item" --reset-identity-col --random-defaults --update-parents
}

create_new_provider_resource() {
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
	{
		"registry.terraform.io/hashicorp/random": {
			"content": $random_content,
			"resource": "random_id.this"
		},
		"registry.terraform.io/hashicorp/null": {
			"content": $null_content,
			"resource": "null_resource.this"
		},

	}
	')

	log "Getting Terragrunt file providers" "INFO"
	cfg_providers=$(terragrunt providers --terragrunt-working-dir $tf_dir 2> /dev/null | grep -oP '─\sprovider\[\K.+(?=\])' | sort -u)
	log "Providers: $(printf "\n%s" "${cfg_providers[@]}")" "DEBUG"

	log "Getting testing providers that are not in terraform directory" "INFO"
	target_testing_provider=$(echo "$testing_providers_data" | jq \
	--arg cfg_providers "${cfg_providers[*]}" '
	(try ($cfg_providers | split(" ")) // []) as $cfg_providers
	| with_entries(select(.key | IN($cfg_providers[]) | not))
	| (keys[0]) as $idx
	| with_entries(select(.key == $idx))
	')
	
	out_file="$tf_dir/$testing_id.tf"
	#convert jq to formatted content and remove escape characters
	content=$(echo "$target_testing_provider" | jq 'map(.content)[0]' | sed -e 's/^.//' -e 's/.$//')
	content=$(echo -e "$content" | tr -d '\')

	log "Adding mock resource content to $out_file:" "DEBUG"
	log "$content" "DEBUG"
	echo "$content" > "$out_file"

	echo "$target_testing_provider"
}

create_random_output() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	local tf_dir=$1
	out_file="$tf_dir/$(openssl rand -base64 10 | tr -dc A-Za-z0-9).tf"
	log "Filepath: $out_file" "DEBUG"

	cat << EOF > "$out_file"
output "test_case_$BATS_TEST_NUMBER" {
	value = "test"
}
EOF
}


main() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	parse_args "$@"

	cd "$abs_repo_dir"

	log "Creating testing branch: $head_ref" "INFO"
	git checkout -B "$head_ref"

	modify_items=$(create_commit_changes "$modify_items")

	commit_item=$(add_commit_to_queue "$commit_item" "$commit_msg")

	log "Switching back to default branch" "DEBUG"
	cd "$abs_repo_dir"
    git checkout "$(git remote show $(git remote) | sed -n '/HEAD branch/s/.*: //p')"
	
	jq --arg commit_item "$commit_item" --arg modify_items "$modify_items" '{"commit": $commit_item, "modify": $modify_items}'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi