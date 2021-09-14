parse_tg_path_args() {
	while (( "$#" )); do
		case "$1" in
			--path)
				if [ -n "$2" ]; then
					tg_dir="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
			;;
			--new-provider-resource)
				new_provider_resource=true
				shift 1
			;;
			*)
				echo "Unknown Option: $1"
				exit 1
			;;
		esac
	done
}

checkout_test_case_branch() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	export TESTING_HEAD_REF="test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
	
	log "Creating testing branch: $TESTING_HEAD_REF" "INFO"
	git checkout -B "$TESTING_HEAD_REF"
}

modify_tg_path() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	
	parse_tg_path_args "$@"

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

add_test_case_pr_to_queue() {
	results=$(query """
	INSERT INTO pr_queue (
        pr_id,
        status,
        base_ref,
		head_ref
	)
	VALUES (
		11,
		'waiting',
		'$TESTING_BASE_REF',
		'$TESTING_HEAD_REF'
	)
	RETURNING *;
	""")

	log "Results:" "DEBUG"
	log "$results" "DEBUG"
}

add_test_case_head_commit_to_queue() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

	if [ -z "$TEST_CASE_REPO_DIR" ]; then
		log "Test case repo directory was not set" "ERROR"
		exit 1
	else
		cd "$TEST_CASE_REPO_DIR"
	fi

	log "Adding testing changes to branch: $(git rev-parse --abbrev-ref HEAD)" "INFO"

	if [ $(git status --short | wc -l) == 0 ]; then
		log "Nothing to commit -- creating dummy file to allow git to create a new commit" "DEBUG"
		touch dummy.txt
	fi

	git add "$(git rev-parse --show-toplevel)/"
	git commit -m $TESTING_HEAD_REF

	export TESTING_COMMIT_ID=$(git log --pretty=format:'%H' -n 1)
	log "Expected next commit in queue: $TESTING_COMMIT_ID" "DEBUG"

	log "Adding testing commit to queue" "INFO"

	results=$(query """
	INSERT INTO commit_queue (
		commit_id,
        pr_id,
        status,
        is_rollback
	)
	VALUES (
		'$TESTING_COMMIT_ID',
		11,
		'waiting',
		false
	)
	RETURNING *;
	""")

	log "Results:" "DEBUG"
	log "$results" "DEBUG"
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