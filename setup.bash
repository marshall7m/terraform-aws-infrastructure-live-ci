#!/bin/bash

cleanup() {
    if [ -n "$1" ] && [ -n "$2" ]; then
        echo "Stopping ECS task"
        aws ecs stop-task --cluster "$1" --task "$2" 1> /dev/null
    fi

    echo "Unmounting"
    sudo umount -f "$local_mount"

    echo "Killing OpenVPN connection"
    sudo killall openvpn
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
    efs_dns=$(echo "$tf_out" | jq -r '.testing_efs_dns.value')
    efs_ip=$(echo "$tf_out" | jq -r '.testing_efs_ip_address.value')
    vpn_endpoint=$(echo "$tf_out" | jq -r '.testing_vpn_client_endpoint.value')
    vpn_private_key=$(echo "$tf_out" | jq -r '.testing_vpn_private_key_content.value')
    vpn_cert=$(echo "$tf_out" | jq -r '.testing_vpn_cert_content.value')

    local_mount="$(dirname "$(realpath $0)")/mnt"
    sudo chown ${USER} "$local_mount"

    echo "Cluster ARN: $cluster_arn"
    echo "Task ARN: $task_arn"
    echo "Subnet IDs: $subnet_id"
    echo "EFS DNS name: $efs_dns"
    echo "EFS IP: $efs_ip"
    echo "VPN Endpoint: $vpn_endpoint"

    client_cfg=$(aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id "$vpn_endpoint" --output text)

    client_cfg=$(cat <<EOT > $PWD/client.ovpn
$client_cfg
<cert>
$vpn_cert
</cert>

<key>
$vpn_private_key
</key>
EOT
)
    echo "Running OpenVPN"
    sudo openvpn --config "$PWD/client.ovpn" --daemon

    vpn_ip=$(aws ec2 describe-client-vpn-connections --client-vpn-endpoint-id "$vpn_endpoint" \
        | jq -r '.Connections[] | select(.Status.Code == "active") | .ClientIp')

    echo "VPN IP: $vpn_ip"

    echo "Adding EFS IP address to local machine's mounts"
    sudo echo "/Users -alldirs $efs_ip" >> /etc/exports
    
    echo "Restarting nfsd"
    sudo nfsd restart

    echo "Checking exports"
    sudo nfsd checkexports

    echo "Mounts:"
    showmount -e

    echo "Mounting to EFS: $local_mount"
    sudo mount -t efs -o vers=4,tcp,rsize=1048576,wsize=1048576,hard,timeo=150,retrans=2,mountport=2049,addr="$efs_ip",clientaddr="$vpn_ip" -w "$efs_ip":/ "$local_mount" || cleanup; exit 1

    task_id=$(aws ecs run-task \
        --cluster "$cluster_arn"  \
        --task-definition "$task_arn" \
        --launch-type FARGATE \
        --platform-version '1.4.0' \
        --enable-execute-command \
        --network-configuration awsvpcConfiguration="{subnets=[$subnet_id],securityGroups=[$sg_id],assignPublicIp=ENABLED}" \
        --region $AWS_REGION | jq -r '.tasks[0].taskArn | split("/") | .[-1]')
    
    if [ "$run_ecs_exec_check" == true ]; then
        bash <( curl -Ls https://raw.githubusercontent.com/aws-containers/amazon-ecs-exec-checker/main/check-ecs-exec.sh ) "$cluster_arn" "$task_id"
    fi

    sleep_time=10
    status=""
    echo ""
    echo "Waiting for task to be running"
    while [ "$status" != "RUNNING" ]; do
        echo "Checking status in $sleep_time seconds..."
        sleep $sleep_time

        status=$(aws ecs describe-tasks \
            --cluster "$cluster_arn" \
            --region $AWS_REGION \
            --tasks "$task_id" | jq -r '.tasks[0].containers[0].managedAgents[] | select(.name == "ExecuteCommandAgent") | .lastStatus')

        echo "Status: $status"

        if [ "$status" == "STOPPED" ]; then
            aws ecs describe-tasks \
            --cluster "$cluster_arn" \
            --region $AWS_REGION \
            --tasks "$task_id"
            exit 1
        fi
    done

    task_ip=$(aws ecs describe-tasks \
        --cluster "$cluster_arn" \
        --region $AWS_REGION \
        --tasks "$task_id" | jq -r '.tasks[0].containers[0].networkInterfaces[0].privateIpv4Address')

    echo "Task IP: $task_ip"
    echo "Task ID: $task_id"

    echo "Running interactive shell within container"
    aws ecs execute-command  \
        --region $AWS_REGION \
        --cluster "$cluster_arn" \
        --task "$task_id" \
        --command "/bin/bash" \
        --interactive
else
    echo '$TESTING_ENV is not set -- (local | remote)' && exit 1
fi