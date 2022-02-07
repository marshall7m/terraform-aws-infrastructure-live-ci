#!/bin/bash

cleanup() {
    if [ -n "$1" ] && [ -n "$2" ]; then
        echo "Stopping ECS task"
        aws ecs stop-task --cluster "$1" --task "$2" 1> /dev/null
    fi

    echo "Unmounting"
    # sudo umount -f "$3"
}

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
    subnet_id=$(echo "$tf_out" | jq -r '.public_subnets_ids.value[0]')
    sg_id=$(echo "$tf_out" | jq -r '.testing_ecs_security_group_id.value')
    local_mount="/tmp/mnt"
    
    echo "Cluster ARN: $cluster_arn"
    echo "Task ARN: $task_arn"
    echo "Subnet IDs: $subnet_id"
    echo "Local Mount: $local_mount"

    while read line; do
        if [[ "$line" =~ "^$local_mount" ]]; then
            export_exists=true
        fi
    done <<< "$(showmount -e localhost)"

    if [ -z "$export_exists" ]; then
        echo "Adding local mount to /etc/exports"
        # sudo echo "/Users -alldirs -mapall=$USER localhost" >> /etc/exports
        
        echo "Restarting nfsd"
        # sudo nfsd restart
    else
        echo "Local mount already added to /etc/exports"
    fi

    echo "Checking exports"
    # sudo nfsd checkexports

    echo "Mounts:"
    showmount -e localhost

    task_id=$(aws ecs run-task \
        --cluster "$cluster_arn"  \
        --task-definition "$task_arn" \
        --launch-type FARGATE \
        --platform-version '1.4.0' \
        --network-configuration awsvpcConfiguration="{subnets=[$subnet_id],securityGroups=[$sg_id],assignPublicIp=ENABLED}" \
        --region $AWS_REGION | jq -r '.tasks[0].taskArn | split("/") | .[-1]')

    sleep_time=10
    status=""
    echo ""
    echo "Waiting for task to be running"
    echo "Task ID: $task_id"
    
    while [ "$status" != "RUNNING" ]; do
        echo "Checking status in $sleep_time seconds..."
        sleep $sleep_time

        status=$(aws ecs describe-tasks \
            --cluster "$cluster_arn" \
            --region $AWS_REGION \
            --tasks "$task_id" | jq -r '.tasks[0] | .lastStatus')

        echo "Status: $status"

        if [ "$status" == "STOPPED" ]; then
            aws ecs describe-tasks \
            --cluster "$cluster_arn" \
            --region $AWS_REGION \
            --tasks "$task_id"
            exit 1
        fi
    done

    task_eni=$(aws ecs describe-tasks \
        --cluster "$cluster_arn" \
        --region $AWS_REGION \
        --tasks "$task_id" | jq -r '.tasks[0].attachments[0].details[] | select(.name == "networkInterfaceId") | .value')
    echo "Task ENI: $task_eni"

    task_ip=$(aws ec2 describe-network-interfaces --network-interface-ids "$task_eni" | jq -r '.NetworkInterfaces[0] | .Association.PublicIp')

    # echo "Mounting $local_mount to ECS task"
    # sudo sshfs root@"$task_ip":/home/ec2-user/src "$local_mount" -o IdentityFile=~/.ssh/testing.pem -o allow_other

    echo "SSH into ECS task"
    ssh -vvv -i ~/.ssh/testing.pem root@"$task_ip"

    # cleanup "$cluster_arn" "$task_id" "$local_mount"
else
    echo '$TESTING_ENV is not set -- (local | remote)' && exit 1
fi