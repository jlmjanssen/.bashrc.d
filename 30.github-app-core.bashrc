# SPDX-FileCopyrightText: 2026 John Janssen <https://github.com/jlmjanssen>
#
# SPDX-License-Identifier: MIT-0

# GitHub App core functions
# Provides: token caching, JWT generation, installation token refresh
# Depends on: jq, curl, openssl
# Does NOT depend on: GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_APP_ACCOUNT

export GITHUB_APP_CACHE="${HOME}/.cache/github_app_tokens.json"

b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

get_jwt_token() {
    # Give the input parameters pretty names.
    local app_id private_key_path
    app_id="$1"
    private_key_path="$2"

    # Determine issued-at-time timestamps, and expiration timestamps.
    # (Seconds since UNIX epoch)
    local -i iat exp
    iat=$(date +%s)
    exp=iat+600

    # Construct the unsigned token from the header and payload.
    local header payload unsigned_token
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | b64url)
    unsigned_token="$header.$payload"

    # Sign the token.
    local signature signed_token
    signature=$(printf '%s' "$unsigned_token"  | openssl dgst -sha256 -sign "$private_key_path" | b64url)
    signed_token="$unsigned_token.$signature"

    # Return the signed JWT token.
    printf "%s\n" "$signed_token"
}

_init_cache() {
    if [[ ! -f "$GITHUB_APP_CACHE" ]]; then
        printf "{}\n" > "$GITHUB_APP_CACHE"
    fi
}

_cache_find_installation_entry() {
    local app_id="$1"
    local account_login="$2"

    jq -r --arg app "$app_id" --arg acct "$account_login" '
        .[$app][]? | select(.account == $acct)
    ' "$GITHUB_APP_CACHE"
}

_cache_set_installation_entry() {
    local app_id="$1"
    local installation_id="$2"
    local account_login="$3"
    local token="$4"
    local expires_at="$5"

    local tmp
    tmp=$(mktemp)

    jq --arg app "$app_id" \
       --argjson inst_id "$installation_id" \
       --arg acct "$account_login" \
       --arg tok "$token" \
       --arg exp "$expires_at" '
       .[$app] = (
           (.[$app] // [])
           | map(select(.installation_id != $inst_id))
           + [{
               installation_id: $inst_id,
               account: $acct,
               token: $tok,
               expires_at: $exp
           }]
       )
    ' "$GITHUB_APP_CACHE" > "$tmp"

    mv "$tmp" "$GITHUB_APP_CACHE"
}

prune_application_token_cache() {
    _init_cache

    local tmp
    tmp=$(mktemp)

    jq '
      # For each app_id key…
      with_entries(
        .value |= (
          # Keep only installations whose expires_at is in the future
          map(
            . as $inst
            | ($inst.expires_at | fromdateiso8601) as $exp
            | now as $now
            | select($exp > $now)
          )
        )
      )
      # Remove app_ids that now have empty lists
      | with_entries(select(.value | length > 0))
    ' "$GITHUB_APP_CACHE" > "$tmp"

    mv "$tmp" "$GITHUB_APP_CACHE"
}

update_application_token_cache() {
    local app_id="$1"
    local private_key_path="$2"
    local account_login="$3"

    _init_cache

    # Look up existing installation entry for this app/account
    local entry
    entry="$(_cache_find_installation_entry "$app_id" "$account_login")"

    if [[ -n "$entry" ]]; then
        local expires_at expires_epoch now_epoch
        expires_at=$(printf "%s" "$entry" | jq -r '.expires_at')
        expires_epoch=$(date -d "$expires_at" +%s)
        now_epoch=$(date +%s)

        # Refresh if less than 5 minutes left
        if (( expires_epoch - now_epoch > 300 )); then
            return 0
        fi
    fi

    # Either no entry or expired → refresh
    local jwt
    jwt="$(get_jwt_token "$app_id" "$private_key_path")"

    # Find installation ID for this account
    local installation_id
    installation_id="$(curl -s \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/app/installations \
        | jq -r ".[] | select(.account.login == \"$account_login\") | .id")"

    if [[ -z "$installation_id" || "$installation_id" == "null" ]]; then
        printf "Error: No installation found for account '%s'\n" "$account_login" >&2
        return 1
    fi

    # Request a new installation token
    local response token expires_at
    response="$(curl -s \
        -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/$installation_id/access_tokens")"

    token=$(printf "%s" "$response" | jq -r '.token')
    expires_at=$(printf "%s" "$response" | jq -r '.expires_at')

    if [[ -z "$token" || "$token" == "null" ]]; then
        printf "Error: Could not retrieve installation token for '%s'\n" "$account_login" >&2
        return 1
    fi

    # Store updated entry
    _cache_set_installation_entry "$app_id" "$installation_id" "$account_login" "$token" "$expires_at"
}

get_application_token() {
    local app_id="$1"
    local private_key_path="$2"
    local account_login="$3"

    _init_cache

    # Ensure the cache is up-to-date
    update_application_token_cache "$app_id" "$private_key_path" "$account_login"

    # Retrieve the installation entry
    local entry
    entry="$(_cache_find_installation_entry "$app_id" "$account_login")"

    if [[ -z "$entry" ]]; then
        printf "Error: No cached token found for app_id=%s account=%s\n" \
            "$app_id" "$account_login" >&2
        return 1
    fi

    # Extract and return the token
    printf "%s\n" "$(printf "%s" "$entry" | jq -r '.token')"
}

list_installations() {
    # Give the input parameters pretty names.
    local app_id private_key_path
    app_id="$1"
    private_key_path="$2"

    # Generate a JWT token that will expire after 10 minutes.
    local jwt_token
    jwt_token="$(create_jwt_token "$app_id" "$private_key_path")"

    # Fetch all installations for this GitHub App.
    local installations_json
    installations_json="$(curl -s \
        -H "Authorization: Bearer $jwt_token" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/app/installations)"

    # If GitHub returned nothing, bail out.
    if [[ -z "$installations_json" || "$installations_json" == "null" ]]; then
        printf "Error: Could not retrieve installations\n" >&2
        return 1
    fi

    # Print a readable list of installations.
    printf "%s\n" "$installations_json" | jq -r '
        .[] | "\(.id)\t\(.account.login)\t\(.account.type)"
    '
}

prune_application_token_cache
