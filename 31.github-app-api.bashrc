# SPDX-FileCopyrightText: 2026 John Janssen <https://github.com/jlmjanssen>
#
# SPDX-License-Identifier: MIT-0

# GitHub App API wrapper
# Provides: gh_app_api (smart REST/GraphQL routing)
# Depends on: core functions, GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_APP_ACCOUNT

GITHUB_APP_ID=2859026
GITHUB_APP_PRIVATE_KEY=/home/john/.ssh/apps/speeltuin-actions.pem
GITHUB_APP_ACCOUNT=speeltuin

gh_app_api() {
    local mode="$1"
    shift

    # Prefer GH_TOKEN if set
    if [[ -n "$GH_TOKEN" ]]; then
        if [[ "$mode" == "graphql" ]]; then
            gh api graphql "$@"
        else
            gh api "$mode" "$@"
        fi
        return
    fi

    # Ensure required env vars exist
    if [[ -z "$GITHUB_APP_ID" || -z "$GITHUB_APP_PRIVATE_KEY" ]]; then
        printf "Error: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY must be set\n" >&2
        return 1
    fi

    case "$mode" in
        # Installation-level GraphQL
        graphql)
            if [[ -z "$GITHUB_APP_ACCOUNT" ]]; then
                printf "Error: GITHUB_APP_ACCOUNT must be set for installation-level GraphQL\n" >&2
                return 1
            fi

            local token
            token=$(get_application_token "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY" "$GITHUB_APP_ACCOUNT")

            GH_TOKEN="$token" gh api graphql "$@"
            ;;

        # App-level GraphQL (rare but possible)
        app-graphql)
            local jwt
            jwt=$(get_jwt_token "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY")

            GH_TOKEN="$jwt" gh api graphql "$@"
            ;;

        # REST fallback (existing behavior)
        *)
            local url="$mode"

            # App-level REST
            if [[ "$url" == https://api.github.com/app || "$url" == https://api.github.com/app/* ]]; then
                local jwt
                jwt=$(get_jwt_token "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY")

                curl -H "Authorization: Bearer $jwt" \
                     -H "Accept: application/vnd.github+json" \
                     "$url" "$@"
                return
            fi

            # Installation-level REST
            if [[ -z "$GITHUB_APP_ACCOUNT" ]]; then
                printf "Error: GITHUB_APP_ACCOUNT must be set for installation-level REST\n" >&2
                return 1
            fi

            local token
            token=$(get_application_token "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY" "$GITHUB_APP_ACCOUNT")

            curl -H "Authorization: Bearer $token" \
                 -H "Accept: application/vnd.github+json" \
                 "$url" "$@"
            ;;
    esac
}
