#!/bin/bash

parse_args() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	modify_paths=()

	while (( "$#" )); do
		case "$1" in
			--clone-url)
				if [ -n "$2" ]; then
					clone_url="$2"
					shift 2
				else
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				;;
			--clone-destination)
				clone_destination="$2"
				shift 2
				;;
			--terragrunt-working-dir)
				terragrunt_working_dir="$2"
				shift 2
				;;
			--skip-terraform-state-setup)
				skip_terraform_state_setup=true
				shift
				;;
			--modify)
				modify_paths+=("$2")
				shift 2
				;;
			*)
				echo "Unknown Option: $1"
				exit 1
				;;
		esac
	done
}

setup_tg_env() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"

    export TESTING_TMP_DIR=$(mktemp -d)
	log "TESTING_TMP_DIR: $TESTING_TMP_DIR" "DEBUG"
	chmod u+x "$TESTING_TMP_DIR"
	log "Changing directory to TESTING_TMP_DIR" "DEBUG"
	cd $TESTING_TMP_DIR
}

teardown_tg_env() {
  if [ $BATS_TEST_COMPLETED ]; then
    rm -rf $TESTING_TMP_DIR
  else
    echo "Did not delete $TESTING_TMP_DIR, as test failed"
  fi
}

setup_existing_provider() {
	cat << EOF > $TESTING_TMP_DIR/main.tf

provider "time" {}

resource "time_static" "test" {}

EOF
    # 'EOF' to escape $
    cat << 'EOF' > $TESTING_TMP_DIR/terragrunt.hcl

terraform {
    source = "${get_terragrunt_dir()}///"
}
EOF

    setup_terragrunt_apply
}

setup_new_provider() {
	declare -a new_providers=("random" "null")
    for provider in "${new_providers[@]}"; do
        cat << EOF >> ./new_provider.tf

provider "$provider" {}
EOF
    done
}

setup_new_provider_with_resource() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	declare -a new_providers=("random")
	declare -a new_providers=("random_id.test")
	cat << EOF > $TESTING_TMP_DIR/new_provider.tf

provider "$new_providers" {}

resource "random_id" "test" {
    byte_length = 8
}
EOF
}

setup_terragrunt_apply() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve
}

clone_testing_repo() {
	log "FUNCNAME=$FUNCNAME" "DEBUG"
	local clone_url=$1
	local clone_destination=$2

	local_clone_git=$clone_destination/.git

	if [ ! -d $local_clone_git ]; then
		git clone "$clone_url" "$clone_destination"
	else
		log ".git already exists in clone destination" "INFO"
	fi
}

parse_tg_graph_deps() {
	dir=$1
	parsed_stack=$(jq -n '{}')

    out=$(terragrunt graph-dependencies --terragrunt_working_dir "$TESTING_TMP_DIR")

    log "Terragrunt graph-dep command out:" "DEBUG"
    log "$out" "DEBUG"

    while read -r line; do
		parent=$( echo "$line" | grep -Po '"\K.+?(?="\s+\->)')
		log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"

		dep=$( echo "$line" | grep -Po '\->\s+"\K.+(?=";)')
		log "Dependency: $(printf "\n\t%s" "$dep")" "DEBUG"

        if [ "$parent" != "" ]; then
            parsed_stack=$( echo $parsed_stack \
                | jq --arg parent "$parent" --arg dep "$dep" '
                    (.[$parent]) |= . + [$dep]
                '
            )
        fi
    done <<< $out

    echo "$parsed_stack"
}

clone_gh_tpl_repo() {
	export TESTING_TMP_REPO_TPL_DIR=$(mktemp -d)
	log "TESTING_TMP_REPO_TPL_DIR: $TESTING_TMP_REPO_TPL_DIR" "DEBUG"
	clone_testing_repo $clone_url $TESTING_TMP_REPO_TPL_DIR
}

# create_executions() {}
# create_account_dim() {}
# create_commit_queue() {}

# TODO:
# Setup execution/account dim based on repo structure
#     - Use mock function to create other arbitrary values
# create finished executions/commits in relation to account/commit tables
# 	- set flags for global values that will effect test results
# 		- account_paths
# 		- account_dependencies
# Create test records within test case for better visibility of what test is testing
