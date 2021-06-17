pr_id="65"
base_ref="bu"
head_ref="hu"
build_num="4"



keys=$(jq -n --arg pr_id "$pr_id" '{":pr_id": {N: $pr_id}}')
in_table=$(aws dynamodb query \
    --table-name mut-infrastructure-ci-pr-queue \
    --projection-expression "PullRequestID" \
    --key-condition-expression "PullRequestID = :pr_id" \
    --expression-attribute-values "$keys" \
    --consistent-read \
    --scan-index-forward \
    --return-consumed-capacity NONE | jq .Count)

if [[ $in_table == 0 ]]; then    
    record=$( jq -n \
        --arg pr_id "$pr_id" \
        --arg base_ref "$base_ref" \
        --arg head_ref "$head_ref" \
        --arg build_num "$build_num" \
        '{PullRequestID: {N: $pr_id}, BaseRef: {S: $base_ref}, HeadRef: {S: $head_ref}, BuildNumber: {N: $build_num}}' )
    echo "Putting PR record in queue"
    echo "$record"
    aws dynamodb put-item \
        --table-name "mut-infrastructure-ci-pr-queue" \
        --item "$record" 
    echo "Successfully put record in queue"
elif [[ $in_table == 1 ]]; then
    echo "Pull Request: ${pr_id} is already in queue"
else
    echo "Duplicate records found in table for PullRequestID: ${pr_id}" 
    exit 1
fi