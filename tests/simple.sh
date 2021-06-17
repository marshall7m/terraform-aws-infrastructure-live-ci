pr_id="0"

attr=$( jq -n \
    --arg base_ref "master" \
    --arg head_ref "test" \
    --arg build_num "3" \
    '[{Name: "BaseRef", Value: $base_ref, Replace: false}, {Name: "HeadRef", Value: $head_ref, Replace: false}, {Name: "BuildNumber", Value: $build_num, Replace: false}]' )
cond=$( jq -n --arg build_num "2" '{"Name": "BuildNumber","Exists": false}')
echo $attr
aws sdb put-attributes \
    --domain-name test \
    --item-name ${pr_id} \
    --attributes "$attr" \
    --expected "$cond"

# next_pr=$(aws sdb select \
#     --select-expression "SELECT * FROM test" \
#     --max-items 1)

# echo