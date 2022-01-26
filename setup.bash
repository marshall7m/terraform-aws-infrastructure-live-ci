#!/bin/bash

# yarn upgrade
TESTING_ENV="remote"
if [ "$TESTING_ENV" == "local" ]; then
    # config for local metadb container
    export PGUSER=testing_user
    export PGPASSWORD=testing_password
    export PGDATABASE=testing_metadb
    export PGHOST=postgres
    export PGPORT=5432
    export ADDITIONAL_PATH=/src/node_modules/.bin

    docker-compose up --detach
    docker-compose exec testing /bin/bash
elif [ "$TESTING_ENV" == "remote" ]; then
    tf_out=$(cd tests/integration && echo "$(terraform output -json)")
    cluster_arn=$(echo "$tf_out" | jq -r '.testing_ecs_cluster_arn.value')
    task_arn=$(echo "$tf_out" | jq -r '.testing_ecs_task_arn.value')
    private_subnet=$(echo "$tf_out" | jq -r '.private_subnets_ids.value[0]')
    sg_id=$(echo "$tf_out" | jq -r '.testing_ecs_security_group_id.value')

    echo "Cluster ARN: $cluster_arn"
    echo "Task ARN: $task_arn"
    echo "Private Subnet IDs: $private_subnet"

    # local_mount="/Users/marshallmamiya/projects/terraform-modules/terraform-aws-infrastructure-live-ci/tmp/*"
    task_id=$(aws ecs run-task \
        --cluster "$cluster_arn"  \
        --task-definition "$task_arn" \
        --launch-type FARGATE \
        --platform-version '1.4.0' \
        --enable-execute-command \
        --platform-version '1.4.0' \
        --network-configuration awsvpcConfiguration="{subnets=[$private_subnet],securityGroups=[$sg_id]}" \
        --region $AWS_REGION | jq -r '.tasks[0].taskArn | split("/") | .[-1]')
    
    echo "Task ID: $task_id"
    
    if [ "$run_ecs_exec_check" == true ]; then
        bash <( curl -Ls https://raw.githubusercontent.com/aws-containers/amazon-ecs-exec-checker/main/check-ecs-exec.sh ) "$cluster_arn" "$task_id"
    fi

    sleep_time=10
    status=""
    echo "Waiting for ExecuteCommandAgent status to be running"
    while [ "$status" != "RUNNING" ]; do
        echo "Checking status in $sleep_time seconds..."
        sleep $sleep_time

        status=$(aws ecs describe-tasks \
            --cluster "$cluster_arn" \
            --region $AWS_REGION \
            --tasks "$task_id" | jq -r '.tasks[0].containers[0].managedAgents[] | select(.name == "ExecuteCommandAgent") | .lastStatus')

        echo "Status: $status"

        if [ "$status" == "STOPPED" ]; then
            echo "ExecuteCommandAgent stopped -- exiting"
            aws ecs describe-tasks \
            --cluster "$cluster_arn" \
            --region $AWS_REGION \
            --tasks "$task_id"
            exit 1
        fi

        # sleep_time=$(( $sleep_time * 2 ))
    done

    echo "Running interactive shell within container"
    
    aws ecs execute-command  \
        --region $AWS_REGION \
        --cluster "$cluster_arn" \
        --task "$task_id" \
        --command "/bin/bash" \
        --interactive
    # # skips creating local metadb container
    # docker-compose run \
    #     -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    #     -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    #     -e AWS_REGION="$AWS_REGION" \
    #     -e AWS_DEFAULT_REGION="$AWS_REGION" \
    #     -e AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
    #     -v /var/run/docker.sock:/var/run/docker.sock \
    #     --entrypoint="bash /src/entrypoint.sh" \
    #     testing /bin/bash
else
    echo '$TESTING_ENV is not set -- (local | remote)' && exit 1
fi