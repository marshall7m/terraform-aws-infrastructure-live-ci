foo=$(jq -n '{
  "infrastructure-live/dev-account/us-west-2/env_one/bar": [
    [
      "infrastructure-live/dev-account/us-west-2/env_one/baz",
      "infrastructure-live/dev-account/us-west-2/global"
    ]
  ],
  "infrastructure-live/dev-account/us-west-2/env_one/baz": [
    [
      "infrastructure-live/dev-account/us-west-2/global"
    ]
  ],
  "infrastructure-live/dev-account/us-west-2/env_one/doo": [
    [
      "infrastructure-live/dev-account/us-west-2/global"
    ]
  ],
  "infrastructure-live/dev-account/us-west-2/env_one/foo": [
    [
      "infrastructure-live/dev-account/us-west-2/env_one/bar"
    ]
  ],
  "infrastructure-live/dev-account/us-west-2/global": [
    []
  ]
}')

# echo ${foo} | jq '([.. | .[]? | strings] | unique) as $uniq_deps 
#     | . as $origin 
#     | with_entries(select([.key] 
#     | inside($uniq_deps) 
#     | not)) 
#     | map_values(. += ($origin[.. | .[]?| strings] | .[] | $origin[.]) )'

# echo ${foo} | jq '. as $origin 
#   | .[] | until($origin[ .. | .[]? | .] == [[]]; . += ["foo"])'

# echo ${foo} | jq '. as $origin 
#   | map_values(. += until($origin[ .. | .[]? | strings] | contains([]); $x))'

# echo ${foo} | jq '. as $origin 
#   | map_values(. += ($origin[ .. | .[]? | strings] | if . != [[]] then . else null end ))'

# echo ${foo} | jq '. as $origin 
#     | map_values(while($origin[ .. | .[]?] != [[]]; . += $origin[ .. | .[]? | . ] ))'


echo ${foo} | jq '. as $origin 
  | .[] | until( length > 5; . += ["foo"])' 

# echo ${foo} | jq '. as $origin | map_values(. += (.| .. | .[]? 
#     | . as $x | select($origin."$x" != null) | ["doo"]))'

#$origin."$x"