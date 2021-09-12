# @test "setup mock tables" {
#     account_stack=$(jq -n '
#     {
#         "directory_dependency/dev-account": ["directory_dependency/security-account"]
#     }
#     ')

#     run setup_mock_finished_status_tables \
#         --based-on-tg-dir "$TEST_CASE_REPO_DIR/directory_dependency" \
#         --account-stack "$account_stack"
    
#     assert_success
# }
