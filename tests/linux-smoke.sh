#!/usr/bin/env bash
# Smoke tests for linux/firefox-debloat.sh. They run with temporary HOME and FIREFOX_POLICY_DIR,
# without sudo and without Firefox installed.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCRIPT="$ROOT/linux/firefox-debloat.sh"
MARK_BEGIN='// >>> firefox-debloat >>>'

FAILS=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

# Creates a clean environment: one profile in the classic path and another outside it, found via profiles.ini.
setup() {
  WORK="$(mktemp -d)"
  export HOME="$WORK/home"
  export FIREFOX_POLICY_DIR="$WORK/policies"
  unset XDG_CONFIG_HOME
  BASE="$HOME/.mozilla/firefox"
  P1="$BASE/abc.default-release"
  P2="$WORK/custom/my-profile"
  mkdir -p "$P1" "$P2" "$WORK/bin"
  printf 'user_pref("browser.startup.page", 3);\n' > "$P1/prefs.js"
  printf 'user_pref("browser.startup.page", 3);\n' > "$P2/prefs.js"
  printf '[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default-release\nIsRelative=1\nPath=abc.default-release\n\n[Profile1]\nName=mine\nIsRelative=0\nPath=%s\n' \
    "$P2" > "$BASE/profiles.ini"
  # Fake pgrep: Firefox is "not running" unless FAKE_FIREFOX_RUNNING=1.
  # shellcheck disable=SC2016  # the expansion belongs to the fake pgrep, not this script
  printf '#!/bin/sh\n[ "${FAKE_FIREFOX_RUNNING:-0}" = 1 ]\n' > "$WORK/bin/pgrep"
  chmod +x "$WORK/bin/pgrep"
  export PATH="$WORK/bin:$ORIG_PATH"
}
teardown() { rm -rf -- "$WORK"; }
run() { "$SCRIPT" "$@" >/dev/null 2>&1; }

POL() { echo "$FIREFOX_POLICY_DIR/policies.json"; }
jqp() { jq -e "$1" "$(POL)" >/dev/null 2>&1; }
blocks() { grep -cxF "$MARK_BEGIN" "$1" || true; }
has_pref() { grep -qF "user_pref(\"$2\"," "$1"; }
lacks() { ! grep -qF "$2" "$1"; }

ORIG_PATH="$PATH"

echo '# apply without a previous policies.json'
setup
run
check 'policies.json equals config/' \
  test "$(jq -S . "$(POL)")" = "$(jq -S . "$ROOT/config/policies.json")"
check 'empty .debloat-orig sentinel' test -e "$(POL).debloat-orig" -a ! -s "$(POL).debloat-orig"
check 'block in the classic profile' test "$(blocks "$P1/user.js")" = 1
check 'block in the profiles.ini profile (IsRelative=0)' test "$(blocks "$P2/user.js")" = 1
check 'DisableAccounts applied' jqp '.policies.DisableAccounts == true'
check 'account pref in the block' has_pref "$P1/user.js" identity.fxaccounts.enabled
check 'translation available by default' jqp '.policies.AIControls.Translations.Value == "available"'
check 'no translation pref by default' lacks "$P1/user.js" browser.ai.control.translations
check 'Locked false by default' jqp '.policies.FirefoxHome.Locked == false'
teardown

echo '# Snap profile'
setup
mkdir -p "$HOME/snap/firefox/common/.mozilla/firefox/snp.default"
touch "$HOME/snap/firefox/common/.mozilla/firefox/snp.default/prefs.js"
run --user-only
check 'block in the Snap profile' test "$(blocks "$HOME/snap/firefox/common/.mozilla/firefox/snp.default/user.js")" = 1
teardown

echo '# apply with a previous policies.json'
setup
mkdir -p "$FIREFOX_POLICY_DIR"
printf '{"policies":{"DisableAppUpdate":true,"FirefoxHome":{"Search":false},"Preferences":{"browser.foo":{"Value":1,"Status":"user"}}}}\n' > "$(POL)"
cp "$(POL)" "$WORK/prev.json"
run
check 'previous top-level key preserved' jqp '.policies.DisableAppUpdate == true'
check 'previous subkey preserved by the merge' jqp '.policies.FirefoxHome.Search == false'
check 'new subkey added' jqp '.policies.FirefoxHome.Stories == false'
check 'previous Preferences preserved' jqp '.policies.Preferences["browser.foo"].Value == 1'
check 'original saved byte for byte' cmp -s "$WORK/prev.json" "$(POL).debloat-orig"
teardown

echo '# apply twice'
setup
printf 'user_pref("my.pref", true);' > "$P1/user.js"   # no trailing newline
run
cp "$(POL)" "$WORK/1.json"; cp "$P1/user.js" "$WORK/1.js"
run
check 'a single block' test "$(blocks "$P1/user.js")" = 1
check 'identical policies.json' cmp -s "$WORK/1.json" "$(POL)"
check 'identical user.js' cmp -s "$WORK/1.js" "$P1/user.js"
check 'previous user.js without newline preserved' test "$(head -n1 "$P1/user.js")" = 'user_pref("my.pref", true);'
check 'marker on its own line' test "$(sed -n 2p "$P1/user.js")" = "$MARK_BEGIN"
teardown

echo '# --lock'
setup
run --lock
check 'every Locked becomes true' jqp '[.. | objects | select(has("Locked")) | .Locked] | all'
check 'Preferences with Status locked' jqp '[.policies.Preferences[].Status] | all(. == "locked")'
teardown

echo '# --block-translations'
setup
run --block-translations
check 'AIControls.Translations blocked' jqp '.policies.AIControls.Translations.Value == "blocked"'
check 'translation pref in the block' grep -qF 'user_pref("browser.ai.control.translations", "blocked");' "$P1/user.js"
teardown

echo '# --keep-sync'
setup
run
run --keep-sync
check 'DisableAccounts removed when run again' jqp '.policies | has("DisableAccounts") | not'
check 'account pref out of the block' lacks "$P1/user.js" identity.fxaccounts.enabled
teardown

echo '# pref that leaves the block is cleared from prefs.js'
setup
run --block-translations
printf 'user_pref("identity.fxaccounts.enabled", false);\nuser_pref("browser.ai.control.translations", "blocked");\n' >> "$P1/prefs.js"
FAKE_FIREFOX_RUNNING=1 run --keep-sync
check 'with Firefox running, prefs.js is left alone' grep -qF identity.fxaccounts.enabled "$P1/prefs.js"
run --block-translations
run --keep-sync
check '--keep-sync clears the account pref from prefs.js' lacks "$P1/prefs.js" identity.fxaccounts.enabled
check 'without --block-translations the translation pref is cleared' lacks "$P1/prefs.js" browser.ai.control.translations
check 'other prefs.js prefs untouched' grep -qF browser.startup.page "$P1/prefs.js"
teardown

echo '# --user-only and --system-only'
setup
run --user-only
check '--user-only does not write policies.json' test ! -e "$(POL)"
check '--user-only writes user.js' test -f "$P1/user.js"
teardown
setup
run --system-only
check '--system-only writes policies.json' test -f "$(POL)"
check '--system-only does not write user.js' test ! -e "$P1/user.js"
teardown

echo '# revert'
setup
mkdir -p "$FIREFOX_POLICY_DIR"
printf '{"policies":{"DisableAppUpdate":true}}\n' > "$(POL)"
cp "$(POL)" "$WORK/prev.json"
printf 'user_pref("my.pref", true);\n' > "$P1/user.js"
cp "$P1/user.js" "$WORK/prev.js"
cp "$P1/prefs.js" "$WORK/prev-prefs.js"
run --block-translations
# Simulates Firefox copying the user.js values into prefs.js.
sed -n 's/^user_pref(/user_pref(/p' "$P1/user.js" | grep -vF my.pref >> "$P1/prefs.js"
if FAKE_FIREFOX_RUNNING=1 run --revert; then fail 'revert aborts with Firefox running'; else pass 'revert aborts with Firefox running'; fi
check 'nothing changed on abort' test "$(blocks "$P1/user.js")" = 1
run --revert
check 'policies.json restored' cmp -s "$WORK/prev.json" "$(POL)"
check '.debloat-orig removed' test ! -e "$(POL).debloat-orig"
check 'user.js restored' cmp -s "$WORK/prev.js" "$P1/user.js"
check 'prefs.js restored' cmp -s "$WORK/prev-prefs.js" "$P1/prefs.js"
check 'user.js with only the block is deleted' test ! -e "$P2/user.js"
teardown

setup
run
run --revert
check 'policies.json that did not exist before is removed' test ! -e "$(POL)" -a ! -e "$(POL).debloat-orig"
teardown

echo '# revert after editing config/ (clears what was applied)'
setup
run
printf 'user_pref("pref.applied.before", false);\n' >> "$P1/prefs.js"
sed -i "/^$(printf '%s' "$MARK_BEGIN" | sed 's|/|\\/|g')\$/a user_pref(\"pref.applied.before\", false);" "$P1/user.js"
run --revert
check 'old block pref removed from prefs.js' lacks "$P1/prefs.js" pref.applied.before
teardown

echo '# presets'
setup
run --preset quick
check 'quick keeps the telemetry policy' jqp '.policies.DisableTelemetry == true'
check 'quick drops the password manager policy' jqp '.policies | has("PasswordManagerEnabled") | not'
check 'quick keeps the account policy out' jqp '.policies | has("DisableAccounts") | not'
check 'quick keeps only the wanted sections' grep -q '// --- Telemetry ---' "$P1/user.js"
check 'quick drops the account section' lacks "$P1/user.js" 'identity.fxaccounts.enabled'
teardown
setup
run --preset strict
check 'strict locks the policies' jqp '[.. | objects | select(has("Locked")) | .Locked] | all'
check 'strict blocks the translation' jqp '.policies.AIControls.Translations.Value == "blocked"'
teardown
setup
run --preset keep-sync
check 'keep-sync keeps the account policy' jqp '.policies | has("DisableAccounts") | not'
check 'keep-sync drops the account pref' lacks "$P1/user.js" identity.fxaccounts.enabled
teardown

echo '# preview'
setup
run --preview
check 'preview writes no policies.json' test ! -e "$(POL)"
check 'preview writes no user.js' test ! -e "$P1/user.js"
teardown

echo '# the ledger keeps other values'
setup
mkdir -p "$FIREFOX_POLICY_DIR"
printf '{"policies":{"DisableAppUpdate":true}}\n' > "$(POL)"
run
# Someone changes one of our policies after we wrote it.
jq '.policies.DisableTelemetry = false' "$(POL)" > "$(POL).new" && mv "$(POL).new" "$(POL)"
run --revert
check 'a changed policy is left alone' jqp '.policies.DisableTelemetry == false'
check 'the other policies are gone' jqp '.policies | has("DisableFirefoxStudies") | not'
check 'a policy that is not ours is kept' jqp '.policies.DisableAppUpdate == true'
teardown

echo
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; fi
echo 'all tests passed'
