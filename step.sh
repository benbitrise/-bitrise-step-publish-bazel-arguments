#!/bin/bash
set -e

echo "Provided invocation id: ${invocation_id}"

split() {
   # Usage: split "string" "delimiter"
   IFS=$'\n' read -d "" -ra arr <<< "${1//$2/$'\n'}"
   printf '%s\n' "${arr[@]}"
}

# Gather all secrets for redaction from BES info

all_secrets=$(curl -s -X "GET" \
  "https://api.bitrise.io/v0.1/apps/${BITRISE_APP_SLUG}/secrets" \
  -H "accept: application/json" \
  -H "Authorization: ${bitrise_access_token}")

secret_keys=($(echo $all_secrets | jq ".secrets | [.[] | .name]" | jq -r '.[]'))
secrets=()

# Iterate over each item
for key in "${secret_keys[@]}"; do
    secret_value=$(curl -s -X "GET" \
    "https://api.bitrise.io/v0.1/apps/${BITRISE_APP_SLUG}/secrets/${key}/value" \
    -H "accept: application/json" \
    -H "Authorization: ${bitrise_access_token}" | jq -r ".value")

    # Add result to the results array
    secrets+=($secret_value)
done

# Clean up raw info

redact_secrets() {
  local info="$1"
  local -a secrets=("${@:2}")

  for secret in "${secrets[@]}"; do
    info=$(sed "s|${secret}|[REDACTED]|g" <<< "$info") 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "A secret redaction failed on the sed command."
    fi
  done

  echo "$info"
}

# Setup annotations plugin to publish BES info

bitrise plugin install https://github.com/bitrise-io/bitrise-plugins-annotations.git
export BITRISEIO_BUILD_ANNOTATIONS_SERVICE_URL=https://build-annotations.services.bitrise.io

# Get BES info

bes_response=$(mktemp)
bes_response_code=$(curl -s -o "${bes_response}" -w "%{http_code}" --request GET --url "https://flare-bes.services.bitrise.io:443/invocations/${invocation_id}" --header "authorization: Bearer ${BITRISEIO_BITRISE_SERVICES_ACCESS_TOKEN}")

echo "Response code from BES: ${bes_response_code}"

if [ "$bes_response_code" != "200" ]; then
    echo "Error: Expected 200"
    exit 0
fi

options=$(cat "$bes_response" | jq '.Started.OptionsDescription' -r)
options=$(echo "${options//"'''"/\"}")
redacted_options=$(redact_secrets "${options}" "${secrets}")

ext_flags=$(cat "$bes_response" | jq '.CommandLine | map(.Options) | map(select(.)) | map(.[]) | map("--\(.Name)=\(.Value|tostring)")|.[]' -r)
ext_flags=$(split "$ext_flags" " ")
redacted_ext_flags=$(redact_secrets "${ext_flags}" "${secrets}")

command=$(cat "$bes_response" | jq '.Started.Command' -r)

# Print redacted BES info to Annotation

MD=$(cat <<-END
## Bazel Command
~~~
bazel $command $(echo $redacted_options | fold -w 100 -s)
~~~

## Extended Flags
~~~
$redacted_ext_flags
~~~
END

)

echo "$MD" | bitrise :annotations annotate -s info