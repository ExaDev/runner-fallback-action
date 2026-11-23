#!/usr/bin/env bash
# Runs scripts/determine-runner.sh with a stubbed curl and checks which label set it selects.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
future=$(( $(date +%s) + 3600 ))
cat > "$tmp/bin/curl" <<STUB
#!/usr/bin/env bash
printf '{"files":{"arc-healthy-until":{"content":"%s"}}}' "\${STUB_HEARTBEAT:-$future}"
STUB
chmod +x "$tmp/bin/curl"

failures=0
selected() { # actor fork repo_private heartbeat
  : > "$tmp/out"
  GITHUB_OUTPUT="$tmp/out" PATH="$tmp/bin:$PATH" GIST_ID=x PREFERRED_LABELS=fleet FALLBACK_LABELS=hosted \
    GITHUB_ACTOR="$1" PR_IS_FORK="$2" REPO_PRIVATE="$3" STUB_HEARTBEAT="${4:-$future}" \
    bash "$here/scripts/determine-runner.sh"
  sed -n 's/^selected-runner=//p' "$tmp/out"
}
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; failures=$((failures + 1)); fi
}

check "private repository with a fresh heartbeat uses the fleet" '["fleet"]' "$(selected octocat "" true)"
check "public repository uses the fallback even with a fresh heartbeat" '["hosted"]' "$(selected octocat "" false)"
check "an event with no repository flag still reads the heartbeat" '["fleet"]' "$(selected octocat "" "")"
check "a fork pull request uses the fallback" '["hosted"]' "$(selected octocat true true)"
check "dependabot uses the fallback" '["hosted"]' "$(selected 'dependabot[bot]' "" true)"
check "a stale heartbeat uses the fallback" '["hosted"]' "$(selected octocat "" true 1)"
exit $((failures > 0))
