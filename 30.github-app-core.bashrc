# SPDX-FileCopyrightText: 2026 John Janssen <https://github.com/jlmjanssen>
#
# SPDX-License-Identifier: MIT-0

# GitHub App core functions
# Provides: token caching, JWT generation, installation token refresh
# Depends on: jq, curl, openssl
# Does NOT depend on: GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_APP_ACCOUNT

export GITHUB_INSTALLATION_CACHE="${HOME}/.cache/github_installation_cache.json"

b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

get_jwt_token() {
    # Give the input parameters pretty names.
    local -r app_id="$1" private_key_path="$2"

    # Determine issued-at-time timestamps, and expiration timestamps.
    # (Seconds since UNIX epoch)
    local -ri iat=$(date +%s)
    local -ri exp=$((iat + 600))

    # Construct the unsigned token from the header and payload.
    local -r header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
    local -r payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${app_id}" | b64url)"
    local -r unsigned_token="${header}.${payload}"

    # Sign the token.
    local -r signature="$(printf '%s' "${unsigned_token}"  | openssl dgst -sha256 -sign "${private_key_path}" | b64url)"
    local -r signed_token="${unsigned_token}.${signature}"

    # Return the signed JWT token.
    printf '%s\n' "$signed_token"
}

_cache_find_installation_entry() {
    # Give the input parameters pretty names.
    local -r app_id="$1" installation_name="$2"
    local -r cache_file="${GITHUB_INSTALLATION_CACHE}"

    # If the cache doesn't exist or is empty, nothing to find
    [[ ! -s "${cache_file}" ]] && { printf ''; return 0; }

    # Extract the installation entry as raw JSON
    jq --arg app "${app_id}" \
       --arg name "${installation_name}" \
       '.[$app][$name] // empty' \
       "${cache_file}"
}

_cache_set_installation_entry() {
    local -r app_id="$1" installation_name="$2" installation_id="$3" token="$4" expires_at="$5"
    local -r cache_file="${GITHUB_INSTALLATION_CACHE}"

    # Ensure the cache file exists and contains valid JSON
    [[ ! -s "${cache_file}" ]] && printf '{}' > "${cache_file}"

    # Update or create the entry
    jq \
      --arg app "$app_id" \
      --arg name "$installation_name" \
      --arg iid "$installation_id" \
      --arg tok "$token" \
      --arg exp "$expires_at" \
      '
      .[$app] = (.[$app] // {}) |
      .[$app][$name] = {
          "installation_id": ($iid | tonumber),
          "token": $tok,
          "expires_at": $exp
      }
      ' \
      "${cache_file}" > "${cache_file}.tmp"

    mv -f -- "${cache_file}.tmp" "${cache_file}"
}

_cache_prune_installation_entries() {
    local -r cache_file="${GITHUB_INSTALLATION_CACHE}"
    local -ri now=$(date +%s)

    # If the cache doesn't exist or is empty, nothing to prune
    [[ ! -s "${cache_file}" ]] && return 0

    jq \
      --argjson now "${now}" \
      '
      # Convert top-level object to entries so we can map over it
      to_entries
      | map(
          .value |= (
              # Convert installation map to entries
              to_entries
              | map(
                  # Keep only entries whose expires_at is in the future
                  select((.value.expires_at | fromdateiso8601) > $now)
              )
              | from_entries
          )
      )
      | from_entries
      ' \
      "${cache_file}" > "${cache_file}.tmp"

    mv -f -- "${cache_file}.tmp" "${cache_file}"
}

get_installation_token() {
    local -r app_id="$1" private_key_path="$2" installation_name="$3"
    local -r cache_file="${GITHUB_INSTALLATION_CACHE}"

    # Try to find an existing entry
    local -r entry="$(_cache_find_installation_entry "${app_id}" "${installation_name}")"
    if [[ -n "${entry}" ]]; then
        local -r expires_at="$(jq -r '.expires_at' <<<"${entry}")"
        local -r token="$(jq -r '.token' <<<"${entry}")"
        local -r installation_id="$(jq -r '.installation_id' <<<"${entry}")"

        # If token is still valid, return it
        if [[ $(date +%s) -lt $(date -d "${expires_at}" +%s) ]]; then
            printf '%s\n' "${token}"
            return 0
        fi
    fi

    # No valid cached token → request a new one
    local -r jwt="$(get_jwt_token "${app_id}" "${private_key_path}")"

    # Fetch installation ID and token from GitHub
    local -r response="$(
        curl -s \
            -H "Authorization: Bearer ${jwt}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app/installations"
    )"

    local -r installation_id="$(
        jq -r --arg name "$installation_name" \
            '.[] | select(.account.login == $name) | .id' <<<"${response}"
    )"

    # Request an installation access token
    local -r token_response="$(
        curl -s \
            -X POST \
            -H "Authorization: Bearer ${jwt}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app/installations/${installation_id}/access_tokens"
    )"

    local -r token="$(jq -r '.token' <<<"${token_response}")"
    local -r expires_at="$(jq -r '.expires_at' <<<"${token_response}")"

    # Update the cache
    _cache_set_installation_entry \
        "${app_id}" \
        "${installation_name}" \
        "${installation_id}" \
        "${token}" \
        "${expires_at}"

    # Prune expired entries
    _cache_prune_installation_entries

    # Return the fresh token
    printf '%s\n' "${token}"
}

list_installations() {
    # Give the input parameters pretty names.
    local -r app_id="$1" private_key_path="$2"

    # Generate a JWT token that will expire after 10 minutes.
    local -r jwt_token="$(get_jwt_token "${app_id}" "${private_key_path}")"

    # Fetch all installations for this GitHub App.
    local -r installations_json="$(
        curl -s \
             -H "Authorization: Bearer ${jwt_token}" \
             -H "Accept: application/vnd.github+json" \
             https://api.github.com/app/installations
    )"

    # If GitHub returned nothing, bail out.
    if [[ -z "${installations_json}" || "${installations_json}" == "null" ]]; then
        printf 'Error: Could not retrieve installations\n' >&2
        return 1
    fi

    # Print a readable list of installations.
    printf '%s\n' "${installations_json}" | jq -r '
        .[] | "\(.id)\t\(.account.login)\t\(.account.type)"
    '
}

_cache_prune_installation_entries
