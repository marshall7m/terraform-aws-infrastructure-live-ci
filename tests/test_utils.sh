source ../files/utils.sh

approval_mapping=$(jq -n '{"../../../mut-infrastructure-ci/dev-account": "soo"}')
export script_logging_level="INFO"
create_execution_artifact "foo" "bar" "$approval_mapping"