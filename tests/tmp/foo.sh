providers=$(terraform providers)

cfg_providers=$(echo "$providers" | grep -oP '─\sprovider\[\K.+(?=\])')

state_providers=$(echo "$providers" | grep -oP '\s{4}provider\[\K.+(?=\])')

echo "config providers:"
echo $cfg_providers
echo
echo "state providers:"
echo $state_providers

for provider in ${state_providers[@]}
do
   array=("${cfg_providers[@]/$provider}") #Quotes when working with strings
done

echo
echo "New Providers:"
echo $array

# use jq to parse terraform.tfstate file
# find occurence of provider address within .resources
# get mode, type, name from resource and concat into resource address if mode == "managed" (not data src)
# add address to array
