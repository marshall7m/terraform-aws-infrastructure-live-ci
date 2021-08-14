export script_logging_level="DEBUG"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../helpers/rollback.sh'
    load 'testing_utils.sh'
    # run_only_test "4"
    setup_tg_env
}

teardown() {
    teardown_tg_env
}

@test "Script is runnable" {
    run rollback.sh
}

@test "New Providers" {
    setup_existing_provider
    
    cat << EOF > $TESTING_TMP_DIR/new_provider.tf

provider "random" {}

resource "random_id" "server" {
    byte_length = 8
}
EOF

    run get_new_providers "$TESTING_TMP_DIR"
    assert_output -p "registry.terraform.io/hashicorp/random"
}

@test "No New Providers" {
    setup_existing_provider

    run get_new_providers "$TESTING_TMP_DIR"
    assert_output -p ''
}


@test "New Resources" {
    setup_existing_provider

    cat << EOF > $TESTING_TMP_DIR/new_provider.tf

provider "random" {}

resource "random_id" "test" {
    byte_length = 8
}
EOF
    new_providers=$(get_new_providers "$TESTING_TMP_DIR")

    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve

    expected="$(jq -n '["random_id.test"]')"
    run get_new_providers_resources "$TESTING_TMP_DIR" "${new_providers[*]}"
    assert_output -p "$expected"
}

@test "No New Resources" {
    setup_existing_provider

    cat << EOF > $TESTING_TMP_DIR/new_provider.tf

provider "random" {}

EOF
    new_providers=$(get_new_providers "$TESTING_TMP_DIR")

    terragrunt init --terragrunt-working-dir "$TESTING_TMP_DIR" && terragrunt apply --terragrunt-working-dir "$TESTING_TMP_DIR" -auto-approve

    expected="$(jq -n '[]')"
    run get_new_providers_resources "$TESTING_TMP_DIR" "${new_providers[*]}"
    assert_output -p "$expected"
}