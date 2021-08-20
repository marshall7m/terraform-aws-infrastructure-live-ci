export script_logging_level="DEBUG"
export MOCK_AWS_CMDS=true




@test "Script is runnable" {
    run deploy.sh
}

@test "Assert Deployment Plan Calls" {
    export DEPLOYMENT_TYPE="Deploy"
    export PLAN_COMMAND="plan"

    source mock_aws_cmds.sh
    run deploy.sh

    assert_output -p "FUNCNAME=update_pr_queue_with_new_providers"
}

@test "Assert Deployment Apply Calls" {
    export DEPLOYMENT_TYPE="Deploy"
    export DEPLOY_COMMAND="apply"
    
    run deploy.sh

    assert_output -p "FUNCNAME=update_pr_queue_with_new_resources"
}

@test "Assert Rollback Plan Calls" {
    export DEPLOYMENT_TYPE="Rollback"
    export PLAN_COMMAND="plan"
    
    run deploy.sh

    assert_output -p "FUNCNAME=update_pr_queue_with_destroy_targets_flags"
    assert_output -p "FUNCNAME=read_destroy_targets_flags"
}

@test "Assert Rollback Apply Calls" {
    export DEPLOYMENT_TYPE="Rollback"
    export DEPLOY_COMMAND="destroy"
    
    run deploy.sh

    assert_output -p "FUNCNAME=read_destroy_targets_flags"
}
