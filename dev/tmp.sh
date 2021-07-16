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
  "infrastructure-live/dev-account/us-west-2/global": [],
  "infrastructure-live/dev-account/us-west-2/env_one/do": [
    ["infrastructure-live/dev-account/us-west-2/env_one/no"]
  ]
}')
#!/bin/bash
in=$(jq -n '{
  "bar": [["re", "de"]],
  "do": [["bar","baz"]],
  "baz": [["re"]],
  "re": [["zoo"]]
}')

echo "expected:"
jq -n '{
  "bar": [["re", "de"], ["zoo"]],
  "do": [["bar","baz"], ["re", "de"], ["re"], ["zoo"]],
  "baz": [["re"], ["zoo"]],
  "re": [["zoo"]]
}'

echo "actual:"
# echo ${in} | jq '. as $origin 
#   | map_values( . + 
#     until(
#       length == 0;
#       (. | flatten | map($origin[.]) | map(select( . != [[]] )) | add ) 
#     )
#   )'

echo ${in} | jq '
  . as $dict
  | map_values(false as $z 
    | until( 
      $z == true;
      [..|strings|$dict[.]] as $p |
      if $p | length != 0 
        then
          (. + $p) | $p
        else
          true as $z | $z   
        end
    )
  )
'

# echo ${in} | jq '
#   . as $dict
#   | map_values(
#     | . as $val
#     | until( 
#       length == 0;
#       reduce (..|strings) as $v ($val; . + $dict[$v]) | 
#     )
#   )
# '

# echo ${foo} | jq '. as $origin 
#   | map_values(. += [$origin[.. | .[]? | strings]])'


# echo ${foo} | jq '. as $origin 
#   | map_values(
#     until(length != 0;
#       $origin[.. | .[]? | strings] as $x
#       | . += $x | $x
#   ))'


# echo ${foo} | jq '. as $origin | map_values(. as $e | .
#   | until(. == null; [(flatten | .[] | $origin[.])] as $y | null 
#   ))'

# echo ${foo} | jq '. as $origin | map_values(. as $e
#   | . + flatten | map(. | flatten | $origin[.])
#   )'

#phase 1
# echo ${foo} | jq '. as $origin 
#   | map_values(. + (flatten | map($origin[.]) | add)
# )'



# echo ${foo} | jq '([.. | .[]? | strings] | unique) as $uniq_deps 
#     | . as $origin 
#     | with_entries(select([.key] 
#     | inside($uniq_deps) 
#     | not)) 
#     | map_values(. as $x | $x.[] += $origin[.] and x += [. | .. | .[]? | strings] ) 
#     | reverse)'

# echo ${foo} | jq '. as $origin | 
#  map_values(until(. += [] | length == 0; . += []))' 
# echo ${foo} | jq '. as $origin 
#   | map_values(. += until($origin[ .. | .[]? | strings] | contains([]); $x))'

# echo ${foo} | jq '. as $origin 
#   | map_values(. += ($origin[ .. | .[]? | strings] | if . != [[]] then . else null end ))'

# echo ${foo} | jq '. as $origin 
#     | map_values(while($origin[ .. | .[]?] != [[]]; . += $origin[ .. | .[]? | . ] ))'

# echo ${foo} | jq '. as $origin | 
#  .[] | until(length > 5; . += ["foo"])' 

# echo ${foo} | jq '. as $origin 
#   | map_values(. | until(($origin[ .. | .[]? | strings]) == []; . += [$origin[ .. | .[]? | strings]]))'

# echo ${foo} | jq '. as $origin | 
#  .[] | until(($origin[ .. | .[]? | strings]) as $x | $x == [[]]; . += ["foo"])' 


# echo ${foo} | jq '. as $origin | map_values(. += (.| .. | .[]? 
#     | . as $x | select($origin."$x" != null) | ["doo"]))'

#$origin."$x"