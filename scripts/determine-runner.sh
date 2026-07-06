#!/usr/bin/env bash
# Determines whether an organization's preferred self-hosted runner pool has
# an online runner carrying every requested label, and emits selected-runner
# / preferred-available outputs accordingly. See action.yml for inputs.
set -euo pipefail

# ExaDev's own default label sets, used when preferred-labels/fallback-labels
# arrive empty -- whether because the caller omitted them (action.yml's own
# defaults already cover that case) or because they were explicitly set to
# an org variable that didn't resolve (e.g. an org-level Actions variable is
# unreachable from a private repo on ExaDev's current GitHub plan). org and
# token have no sensible universal default and remain hard-required below.
readonly DEFAULT_PREFERRED_LABELS='self-hosted,linux,ARM64,act-latest,m3'
readonly DEFAULT_FALLBACK_LABELS='ubuntu-latest'

validate_inputs() {
  : "${ORG:?org input is required}"
  : "${TOKEN:?token input is required}"

  if [[ -z "${PREFERRED_LABELS:-}" ]]; then
    PREFERRED_LABELS="$DEFAULT_PREFERRED_LABELS"
  fi
  if [[ -z "${FALLBACK_LABELS:-}" ]]; then
    FALLBACK_LABELS="$DEFAULT_FALLBACK_LABELS"
  fi
}

# Converts a comma-separated label string into a JSON array of trimmed
# strings, preserving whatever letter case the caller supplied.
labels_to_json_array() {
  local raw="$1"
  printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | jq -R . | jq -sc .
}

# Lowercases every entry of a JSON array of strings, for case-insensitive
# comparison against runner labels.
lowercase_json_array() {
  local json_array="$1"
  jq -c '[.[] | ascii_downcase]' <<< "$json_array"
}

# Streams every online runner for the org across all pages of the paginated
# listing endpoint. Fails (non-zero exit) on any API/auth error.
fetch_online_runners() {
  local org="$1"
  if ! GH_TOKEN="$TOKEN" gh api \
    --paginate \
    -H "Accept: application/vnd.github+json" \
    "/orgs/${org}/actions/runners" \
    --jq '.runners[] | select(.status == "online")'; then
    echo "::error::Failed to list self-hosted runners for organization '${org}'" >&2
    return 1
  fi
}

# Returns success if the single given runner's own labels are a superset of
# the (already-lowercased) preferred label set. A runner that is online but
# busy still counts - busy-ness is never checked here.
runner_has_preferred_labels() {
  local runner_json="$1"
  local preferred_lower_json="$2"
  jq -e --argjson pref "$preferred_lower_json" '
    ([.labels[].name | ascii_downcase]) as $runner_labels
    | ($pref - $runner_labels) == []
  ' > /dev/null <<< "$runner_json"
}

# Scans the newline-delimited online-runner JSON for one runner that carries
# the entire preferred label set. Echoes "true"/"false".
find_matching_runner() {
  local runners_ndjson="$1"
  local preferred_lower_json="$2"
  local runner_json

  if [[ -z "$runners_ndjson" ]]; then
    echo "false"
    return 0
  fi

  while IFS= read -r runner_json; do
    [[ -z "$runner_json" ]] && continue
    if runner_has_preferred_labels "$runner_json" "$preferred_lower_json"; then
      echo "true"
      return 0
    fi
  done <<< "$runners_ndjson"

  echo "false"
}

main() {
  validate_inputs

  local preferred_json preferred_lower_json
  preferred_json="$(labels_to_json_array "$PREFERRED_LABELS")"
  preferred_lower_json="$(lowercase_json_array "$preferred_json")"

  local runners_ndjson
  if ! runners_ndjson="$(fetch_online_runners "$ORG")"; then
    exit 1
  fi

  local match_found
  match_found="$(find_matching_runner "$runners_ndjson" "$preferred_lower_json")"

  local selected_runner_json preferred_available
  if [[ "$match_found" == "true" ]]; then
    selected_runner_json="$preferred_json"
    preferred_available="true"
  else
    selected_runner_json="$(labels_to_json_array "$FALLBACK_LABELS")"
    preferred_available="false"
  fi

  echo "selected-runner=${selected_runner_json}" >> "$GITHUB_OUTPUT"
  echo "preferred-available=${preferred_available}" >> "$GITHUB_OUTPUT"
}

main "$@"
