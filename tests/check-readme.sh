#!/usr/bin/env bash
# Fails if any item from config/ (or platform-specific policy) does not appear in README.md,
# in backticks, like `browser.ml.chat.enabled` or `FirefoxHome.Stories`.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
README="$ROOT/README.md"

# Policies added by the platform scripts, outside the shared config/.
PLATFORM_POLICIES=(DisableDefaultBrowserAgent)

items() {
  # user.js prefs.
  sed -n 's/^[[:space:]]*user_pref("\([^"]*\)".*/\1/p' "$ROOT/config/user.js"
  # Policies: top-level name and, for object policies, "Policy.Key" (except Locked).
  # In Preferences, the keys are prefs and appear under their own name.
  jq -r '.policies | to_entries[] |
    .key,
    (if (.value | type) == "object" then
       (.value | keys[] | select(. != "Locked")) as $k |
       if .key == "Preferences" then $k else "\(.key).\($k)" end
     else empty end)' "$ROOT/config/policies.json"
  printf '%s\n' "${PLATFORM_POLICIES[@]}"
}

missing=0
while IFS= read -r item; do
  if ! grep -qF -- "\`$item\`" "$README"; then
    echo "missing from README: $item"
    missing=$((missing + 1))
  fi
done < <(items | sort -u)

if (( missing )); then
  echo "$missing item(s) from config/ not documented in README.md"
  exit 1
fi
echo "README.md covers every item in config/"
