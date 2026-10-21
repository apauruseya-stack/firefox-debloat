#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are used on purpose for jq filters and sed patterns
# firefox-debloat.sh: disables Firefox telemetry, ads, recommendations and AI features.
#
# Works in two layers:
#   1. policies.json (system-wide, asks for sudo): Mozilla's official policies. They apply to all
#      profiles, survive updates and show up in about:policies.
#   2. user.js (per profile): prefs that policies can't reach. Everything goes inside a delimited
#      block, so your existing user.js is preserved.
#
# The content of both layers comes from config/policies.json and config/user.js. Edit those files
# to customize and run the script again.
#
# Usage:
#   ./firefox-debloat.sh                       apply everything
#   ./firefox-debloat.sh --user-only           user.js only (no sudo)
#   ./firefox-debloat.sh --system-only         policies.json only
#   ./firefox-debloat.sh --lock                lock the policies (can't be changed from the UI)
#   ./firefox-debloat.sh --block-translations  also block local (on-device) translation
#   ./firefox-debloat.sh --keep-sync           keep Firefox Account and Sync working
#   ./firefox-debloat.sh --revert              undo what the script applied (close Firefox first)
#   ./firefox-debloat.sh --preset NAME         apply a preset (quick, recommended, strict, keep-sync)
#   ./firefox-debloat.sh --list-presets        list the presets and exit
#   ./firefox-debloat.sh --preview             show what would change and write nothing
#
# Requires: jq.
# On the first run, the existing policies.json is saved as policies.json.debloat-orig. Every run
# writes that original merged with config/, so manual edits to policies.json made after that are
# overwritten (edit config/ or the .debloat-orig instead).
#
# Optional variables:
#   FIREFOX_POLICY_DIR       where policies.json lives (default: /etc/firefox/policies)
#   FIREFOX_DEBLOAT_LEDGER   ledger file for the policies (default: /var/lib/firefox-debloat/ledger.json)
#   FIREFOX_DEBLOAT_USER_LEDGER  ledger file for the profiles (default: ~/.local/share/firefox-debloat/ledger.json)

set -euo pipefail

POLICY_DIR="${FIREFOX_POLICY_DIR:-/etc/firefox/policies}"
POLICY_FILE="$POLICY_DIR/policies.json"
POLICY_ORIG="$POLICY_FILE.debloat-orig"   # copy of the original; empty file = there was none
CONFIG_DIR="$(dirname "$(readlink -f "$0")")/../config"
CONFIG_POLICIES="$CONFIG_DIR/policies.json"
CONFIG_USERJS="$CONFIG_DIR/user.js"
CONFIG_PRESETS="$CONFIG_DIR/presets.json"
CONFIG_RISK="$CONFIG_DIR/risk.json"
MARK_BEGIN='// >>> firefox-debloat >>>'
MARK_END='// <<< firefox-debloat <<<'
SYSTEM_LEDGER="${FIREFOX_DEBLOAT_LEDGER:-$(dirname -- "$POLICY_DIR")/firefox-debloat-ledger.json}"
USER_LEDGER="${FIREFOX_DEBLOAT_USER_LEDGER:-$HOME/.local/share/firefox-debloat/ledger.json}"

DO_USER=1
DO_SYSTEM=1
LOCKED=false
BLOCK_TRANSLATIONS=0
KEEP_SYNC=0
REVERT=0
PRESET=""
PREVIEW=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

while (( $# )); do
  case "$1" in
    --user-only)          DO_SYSTEM=0 ;;
    --system-only)        DO_USER=0 ;;
    --lock)               LOCKED=true ;;
    --block-translations) BLOCK_TRANSLATIONS=1 ;;
    --keep-sync)          KEEP_SYNC=1 ;;
    --revert)             REVERT=1 ;;
    --preview)            PREVIEW=1 ;;
    --list-presets)       LIST_PRESETS=1 ;;
    --preset)
      PRESET="${2:-}"
      [[ -n "$PRESET" ]] || die "--preset needs a name (see --list-presets)."
      shift
      ;;
    --preset=*)           PRESET="${1#--preset=}" ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Presets, risk labels and the ledger
# ---------------------------------------------------------------------------------------------
# Risk label of a policy: safe, low, medium, high or unknown.
risk_of() {
  local name="$1" risk
  [[ -r "$CONFIG_RISK" ]] || { echo "unknown"; return 0; }
  risk="$(jq -r --arg n "$name" '.policies[$n].risk // "unknown"' "$CONFIG_RISK" 2>/dev/null)" || risk="unknown"
  echo "${risk:-unknown}"
}

risk_title() {
  local name="$1" title
  [[ -r "$CONFIG_RISK" ]] || { echo "$name"; return 0; }
  title="$(jq -r --arg n "$name" '.policies[$n].title // $n' "$CONFIG_RISK" 2>/dev/null)" || title="$name"
  echo "${title:-$name}"
}

# Prints the risk label in colour.
print_risk() {
  case "$1" in
    safe|low)  printf '\033[1;32m[%s]\033[0m' "$1" ;;
    medium)    printf '\033[1;33m[%s]\033[0m' "$1" ;;
    high)      printf '\033[1;31m[%s]\033[0m' "$1" ;;
    *)         printf '\033[1;90m[%s]\033[0m' "$1" ;;
  esac
}

list_presets() {
  [[ -r "$CONFIG_PRESETS" ]] || die "No presets file at $CONFIG_PRESETS"
  info "Available presets"
  jq -r '.presets | to_entries[] | "\(.key)\t\(.value.risk)\t\(.value.title)\t\(.value.summary)"' \
    "$CONFIG_PRESETS" | while IFS=$'\t' read -r key risk title summary; do
      print_risk "$risk"
      printf '  \033[1;36m%s\033[0m - %s: %s\n' "$key" "$title" "$summary"
    done
  printf '\nUse --preset <name> to pick one, or --preview to see what it would change.\n'
}

# Reads the preset and applies the flags it defines.
resolve_preset() {
  [[ -n "$PRESET" ]] || return 0
  [[ -r "$CONFIG_PRESETS" ]] || die "Preset file not found: $CONFIG_PRESETS"
  jq -e --arg p "$PRESET" '.presets[$p]' "$CONFIG_PRESETS" >/dev/null 2>&1 \
    || die "Unknown preset '$PRESET'. Available: $(jq -r '.presets | keys | join(", ")' "$CONFIG_PRESETS")"
  if [[ "$(jq -r --arg p "$PRESET" '.presets[$p].lock // false' "$CONFIG_PRESETS")" == "true" ]]; then
    LOCKED=true
  fi
  if [[ "$(jq -r --arg p "$PRESET" '.presets[$p].block_translations // false' "$CONFIG_PRESETS")" == "true" ]]; then
    BLOCK_TRANSLATIONS=1
  fi
  if [[ "$(jq -r --arg p "$PRESET" '.presets[$p].keep_sync // false' "$CONFIG_PRESETS")" == "true" ]]; then
    KEEP_SYNC=1
  fi
  return 0
}

# The list of policy names a preset keeps ("*" for all of them), one per line.
preset_policies() {
  [[ -n "$PRESET" ]] || { echo '*'; return 0; }
  jqr -r --arg p "$PRESET" '.presets[$p].policies // "*" | if type == "array" then .[] else . end' "$CONFIG_PRESETS"
}

# The list of user.js sections a preset keeps ("*" for all of them), one per line.
preset_sections() {
  [[ -n "$PRESET" ]] || { echo '*'; return 0; }
  jqr -r --arg p "$PRESET" '.presets[$p].sections // "*" | if type == "array" then .[] else . end' "$CONFIG_PRESETS"
}

# Keeps only the wanted sections of config/user.js. The text before the first section is kept.
filter_sections() {
  local want_list="$1"
  awk -v want="$want_list" '
    BEGIN {
      n = split(want, parts, "\n")
      for (i = 1; i <= n; i++) if (parts[i] != "") keep[parts[i]] = 1
      all = (parts[1] == "*")
    }
    /^[[:space:]]*\/\/ --- .* ---[[:space:]]*$/ {
      name = $0
      sub(/^[[:space:]]*\/\/ --- /, "", name)
      sub(/ ---[[:space:]]*$/, "", name)
      keepit = all ? 1 : (name in keep)
      if (keepit) print
      next
    }
    { if (keepit) print }
  '
}

# Ledger helpers. The ledger remembers what this tool wrote, so --revert only undoes that.
# jq is called through jqr so that a Windows jq build (which ends lines with CRLF) cannot break
# the read loops below.
jqr() { jq "$@" | tr -d '\r'; }

ledger_read() {
  local path="$1"
  if [[ -r "$path" ]]; then
    jqr -c . "$path" 2>/dev/null || echo '{"policies":{},"userjs":{}}'
  else
    echo '{"policies":{},"userjs":{}}'
  fi
}

ledger_write() {
  local path="$1" content="$2"
  mkdir -p -- "$(dirname -- "$path")" 2>/dev/null || true
  printf '%s\n' "$content" > "$path" 2>/dev/null || warn "Could not write the ledger at $path."
}

command -v jq >/dev/null 2>&1 || die "jq is required. Install it with: sudo pacman -S jq | sudo apt install jq | sudo dnf install jq"
for f in "$CONFIG_POLICIES" "$CONFIG_USERJS"; do
  [[ -r "$f" ]] || die "Config file not found: $f"
done
jq -e '.policies | type == "object"' "$CONFIG_POLICIES" >/dev/null 2>&1 \
  || die "$CONFIG_POLICIES is invalid (it must be JSON with a \"policies\" object)."

# Only uses sudo if the policy destination is not writable by the current user.
policy_dir_writable() {
  local d="$POLICY_DIR"
  while [[ ! -e "$d" ]]; do d="$(dirname -- "$d")"; done
  [[ -w "$d" ]] && { [[ ! -e "$POLICY_FILE" ]] || [[ -w "$POLICY_FILE" ]]; }
}
as_root() { if [[ $EUID -eq 0 ]] || policy_dir_writable; then "$@"; else sudo "$@"; fi; }
firefox_running() { pgrep -x 'firefox|firefox-bin' >/dev/null 2>&1; }

# Profiles = directories that already have prefs.js (Firefox must have been opened at least once).
find_profiles() {
  local bases=(
    "$HOME/.mozilla/firefox"                                   # classic path
    "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"        # new XDG-style profiles
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"      # Flatpak
    "$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox"
    "$HOME/snap/firefox/common/.mozilla/firefox"               # Snap
  )
  local b d
  for b in "${bases[@]}"; do
    [[ -d "$b" ]] || continue
    find "$(readlink -f -- "$b")" -mindepth 2 -maxdepth 2 -name prefs.js -printf '%h\n'
    # Profiles in custom locations only show up in profiles.ini.
    if [[ -f "$b/profiles.ini" ]]; then
      while IFS= read -r d; do
        [[ -f "$d/prefs.js" ]] && readlink -f -- "$d"
      done < <(profiles_ini_paths "$b")
    fi
  done | sort -u
}

# Lists the paths of the [Profile*] sections in profiles.ini; IsRelative=0 means an absolute path.
profiles_ini_paths() {
  awk -v base="$1" '
    function flush() {
      if (in_profile && path != "") print (rel == "0" ? path : base "/" path)
      in_profile = 0; path = ""; rel = "1"
    }
    { sub(/\r$/, "") }
    /^\[/ { flush(); in_profile = ($0 ~ /^\[Profile[0-9]+\]$/); next }
    in_profile && /^Path=/       { path = substr($0, 6) }
    in_profile && /^IsRelative=/ { rel = substr($0, 12) }
    END { flush() }
  ' "$1/profiles.ini"
}

# ---------------------------------------------------------------------------------------------
# user.js
# ---------------------------------------------------------------------------------------------
userjs_block() {
  echo "$MARK_BEGIN"
  echo '// Generated by firefox-debloat from config/user.js. This block is rewritten on every run:'
  echo '// put your personal prefs outside of it.'
  echo
  # Strips CRLF (in case the file was edited on Windows), keeps only the wanted sections and,
  # with --keep-sync, drops the account pref.
  local body
  body="$(sed 's/\r$//' -- "$CONFIG_USERJS" | filter_sections "$(preset_sections)")"
  if (( KEEP_SYNC )); then
    body="$(printf '%s\n' "$body" | sed '/^[[:space:]]*user_pref("identity\.fxaccounts\.enabled",/d')"
  fi
  printf '%s\n' "$body"
  if [[ -n "$(tail -c1 -- "$CONFIG_USERJS")" ]]; then echo; fi
  if (( BLOCK_TRANSLATIONS )); then
    echo
    echo '// Blocks local translation (--block-translations).'
    echo 'user_pref("browser.ai.control.translations", "blocked");'
  fi
  echo "$MARK_END"
}

prefs_in() { sed -n 's/^[[:space:]]*user_pref("\([^"]*\)".*/\1/p'; }
pref_names() { userjs_block | prefs_in; }

# Prefs currently inside the block of a user.js (what was actually applied).
block_pref_names() {
  [[ -f "$1" ]] || return 0
  sed -n "\\|^${MARK_BEGIN}\$|,\\|^${MARK_END}\$|p" "$1" | prefs_in
}

strip_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -i "\\|^${MARK_BEGIN}\$|,\\|^${MARK_END}\$|d" "$f"
}

# Deletes from prefs.js the prefs listed on standard input (one per line). Firefox copies user.js
# values into prefs.js; without this they would stay active.
clear_prefs() {
  local prefs="$1" patterns tmp
  [[ -f "$prefs" ]] || return 0
  patterns="$(mktemp)"
  sed 's/.*/user_pref("&",/' > "$patterns"
  if [[ -s "$patterns" ]]; then
    tmp="$(mktemp)"
    grep -vF -f "$patterns" "$prefs" > "$tmp" || true
    cat "$tmp" > "$prefs"
    rm -f -- "$tmp"
  fi
  rm -f -- "$patterns"
}

apply_user() {
  local profiles p f running=0 removed ledger newledger
  mapfile -t profiles < <(find_profiles)
  if (( ${#profiles[@]} == 0 )); then
    warn "No Firefox profile found. Open Firefox once and run again."
    return 0
  fi
  if firefox_running; then
    running=1
    warn "Firefox is running: user.js is only read on the next start."
  fi
  for p in "${profiles[@]}"; do
    f="$p/user.js"
    # Prefs that were in the block and left it (config/ edited or --keep-sync): the old value would
    # stay in prefs.js, so it is deleted and the pref goes back to its default.
    removed="$(comm -23 <(block_pref_names "$f" | sort -u) <(pref_names | sort -u))"
    strip_block "$f"
    if [[ -s "$f" && -n "$(tail -c1 "$f")" ]]; then echo >> "$f"; fi
    userjs_block >> "$f"
    if [[ -n "$removed" ]]; then
      if (( running )); then
        warn "Close Firefox and reset in about:config the prefs that left the block: ${removed//$'\n'/, }"
      else
        clear_prefs "$p/prefs.js" <<< "$removed"
        info "Prefs that left the block were reset to default: ${removed//$'\n'/, }"
      fi
    fi
    info "user.js updated: $p"
  done

  # Ledger: remember the preferences this tool wrote, so --revert can undo exactly this.
  values_json="$(pref_names | jq -R . | jq -s -c .)"
  ledger="$(ledger_read "$USER_LEDGER")"
  newledger="$(printf '%s' "$ledger" | jq -c --arg p "$p" --argjson v "$values_json" \
    '.userjs[$p] = {values: {prefs: $v}}')"
  ledger_write "$USER_LEDGER" "$newledger"
}

revert_user() {
  local profiles p f ledger
  if firefox_running; then
    die "Close Firefox before reverting (it rewrites prefs.js on exit)."
  fi
  BLOCK_TRANSLATIONS=1   # makes sure the optional prefs are cleared too
  KEEP_SYNC=0
  ledger="$(ledger_read "$USER_LEDGER")"
  mapfile -t profiles < <(find_profiles)
  for p in "${profiles[@]}"; do
    f="$p/user.js"
    # Clears what is in config/ today, what was applied and what the ledger says we wrote.
    { pref_names; block_pref_names "$f"; \
      printf '%s' "$ledger" | jqr -r --arg p "$p" '.userjs[$p].values.prefs[]? // empty'; } \
      | sort -u | clear_prefs "$p/prefs.js"
    strip_block "$f"
    if [[ -f "$f" ]] && ! grep -q '[^[:space:]]' "$f"; then rm -f -- "$f"; fi
    info "Reverted: $p"
    newledger="$(printf '%s' "$ledger" | jq -c --arg p "$p" 'del(.userjs[$p])')"
    ledger_write "$USER_LEDGER" "$newledger"
    ledger="$newledger"
  done
  warn "The block prefs were reset to default, including any you had changed by hand before."
}

# ---------------------------------------------------------------------------------------------
# policies.json
# ---------------------------------------------------------------------------------------------
policies_json() {
  local filter='.' inc inc_json
  if [[ $LOCKED == true ]]; then
    filter+=' | walk(if type == "object" and has("Locked") then .Locked = true else . end)'
    filter+=' | if .policies.Preferences then .policies.Preferences |= map_values('
    filter+='if type == "object" then .Status = "locked" else . end) else . end'
  fi
  if (( BLOCK_TRANSLATIONS )); then
    filter+=' | .policies.AIControls.Translations.Value = "blocked"'
  fi
  if (( KEEP_SYNC )); then
    filter+=' | del(.policies.DisableAccounts)'
  fi
  inc="$(preset_policies)"
  if [[ "$inc" != '*' ]]; then
    inc_json="$(printf '%s\n' "$inc" | jq -R . | jq -s -c .)"
    filter+=' | .policies |= with_entries(select(.key as $k | ($inc | index($k)) != null))'
    jq --argjson inc "$inc_json" "$filter" "$CONFIG_POLICIES"
    return 0
  fi
  jq "$filter" "$CONFIG_POLICIES"
}

# Shows what the policies step would change, without writing anything.
preview_policies() {
  local desired current name value cur status
  desired="$(policies_json)"
  if [[ -f "$POLICY_FILE" ]]; then
    current="$(jq -c '.policies // {}' "$POLICY_FILE" 2>/dev/null || echo '{}')"
  else
    current='{}'
  fi
  info "Preview: policies at $POLICY_FILE"
  while IFS=$'\t' read -r name value; do
    cur="$(printf '%s' "$current" | jq -c --arg n "$name" 'if has($n) then .[$n] else null end')"
    if [[ "$cur" == "null" ]]; then status="add"; elif [[ "$cur" == "$value" ]]; then status="same"; else status="change"; fi
    print_risk "$(risk_of "$name")"
    printf '  %-8s %-40s %s\n' "$status" "$name" "$(risk_title "$name")"
  done < <(printf '%s\n' "$desired" | jq -r '.policies | to_entries[] | "\(.key)\t\(.value | tojson)"')
  printf '\nNothing was written. Run without --preview to apply.\n'
}

# Shows what the user.js step would change, without writing anything.
preview_user() {
  local profiles p file added removed
  mapfile -t profiles < <(find_profiles)
  info "Preview: $(pref_names | wc -l) preferences in ${#profiles[@]} profile(s)"
  for p in "${profiles[@]}"; do
    file="$p/user.js"
    added="$(comm -13 <(block_pref_names "$file" | sort -u) <(pref_names | sort -u))"
    removed="$(comm -23 <(block_pref_names "$file" | sort -u) <(pref_names | sort -u))"
    printf '  \033[1;36m%s\033[0m\n' "$p"
    printf '    added:   %s preference(s)\n' "$(printf '%s' "$added" | grep -c . || true)"
    printf '    removed: %s preference(s)\n' "$(printf '%s' "$removed" | grep -c . || true)"
  done
  printf '\nNothing was written. Run without --preview to apply.\n'
}

apply_system() {
  local tmp values_json ledger newledger
  tmp="$(mktemp)"
  policies_json > "$tmp"

  # Saves the original state only on the first run, so --revert knows what to restore.
  if [[ ! -e "$POLICY_ORIG" ]]; then
    if [[ -f "$POLICY_FILE" ]]; then
      as_root cp -p -- "$POLICY_FILE" "$POLICY_ORIG"
    else
      as_root mkdir -p -- "$POLICY_DIR"
      as_root touch -- "$POLICY_ORIG"
    fi
  fi

  # The merge always starts from the original, not the current file: this way a policy removed
  # from config/ (or turned off by a flag, like --keep-sync) disappears on the next run.
  if [[ -s "$POLICY_ORIG" ]]; then
    if jq -s '.[0] * .[1]' "$POLICY_ORIG" "$tmp" > "$tmp.merged" 2>/dev/null; then
      mv -- "$tmp.merged" "$tmp"
      info "Original policies.json merged with the firefox-debloat policies."
    else
      rm -f -- "$tmp.merged"
      warn "Original policies.json is invalid; it will be replaced (copy at $POLICY_ORIG)."
    fi
  fi

  as_root install -Dm644 -- "$tmp" "$POLICY_FILE"

  # Ledger: remember what this tool wrote, so --revert can undo exactly this.
  values_json="$(jq -c '.policies | to_entries | map({(.key): (.value | tojson)}) | add // {}' "$tmp")"
  ledger="$(ledger_read "$SYSTEM_LEDGER")"
  newledger="$(printf '%s' "$ledger" | jq -c --arg f "$POLICY_FILE" --argjson v "$values_json" \
    '.policies[$f] = {values: $v}')"
  as_root mkdir -p -- "$(dirname -- "$SYSTEM_LEDGER")" 2>/dev/null || true
  printf '%s\n' "$newledger" | as_root tee "$SYSTEM_LEDGER" >/dev/null 2>&1 \
    || warn "Could not write the ledger at $SYSTEM_LEDGER."

  rm -f -- "$tmp"
  info "Policies installed at $POLICY_FILE"
}

revert_system() {
  local ledger mine kept="" changed=0 tmp written now
  ledger="$(ledger_read "$SYSTEM_LEDGER")"
  mine="$(printf '%s' "$ledger" | jqr -r --arg f "$POLICY_FILE" '.policies[$f].values // {} | keys[]' 2>/dev/null || true)"
  if [[ ! -e "$POLICY_ORIG" ]] && [[ -z "$mine" ]]; then
    warn "Nothing to revert in $POLICY_DIR (the script was not applied there)."
    return 0
  fi

  # Looks for values that changed after we wrote them: those must not be touched.
  if [[ -f "$POLICY_FILE" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      written="$(printf '%s' "$ledger" | jqr -r --arg f "$POLICY_FILE" --arg n "$name" '.policies[$f].values | if has($n) then .[$n] else "" end')"
      now="$(jqr -c --arg n "$name" '.policies | if has($n) then .[$n] else null end' "$POLICY_FILE" 2>/dev/null || echo null)"
      if [[ "$now" != "null" && "$now" != "$written" ]]; then
        changed=1
        kept="${kept:+$kept, }$name"
      fi
    done <<< "$mine"
  fi

  if (( changed == 0 )); then
    # Nothing changed behind our back: the original file is restored byte for byte.
    if [[ -s "$POLICY_ORIG" ]]; then
      as_root mv -f -- "$POLICY_ORIG" "$POLICY_FILE"
      info "Original policies.json restored."
    else
      as_root rm -f -- "$POLICY_FILE" "$POLICY_ORIG"
      info "policies.json removed (it did not exist before)."
    fi
  else
    warn "These policies changed after we wrote them, so they were left alone: $kept"
    tmp="$(mktemp)"
    if [[ -f "$POLICY_FILE" ]]; then cp -- "$POLICY_FILE" "$tmp"; else echo '{"policies":{}}' > "$tmp"; fi
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      written="$(printf '%s' "$ledger" | jqr -r --arg f "$POLICY_FILE" --arg n "$name" '.policies[$f].values | if has($n) then .[$n] else "" end')"
      now="$(jqr -c --arg n "$name" '.policies | if has($n) then .[$n] else null end' "$tmp" 2>/dev/null || echo null)"
      if [[ "$now" != "null" && "$now" == "$written" ]]; then
        jq --arg n "$name" 'del(.policies[$n])' "$tmp" > "$tmp.new" && mv -- "$tmp.new" "$tmp"
      fi
    done <<< "$mine"
    # Anything that existed before we first wrote is put back.
    if [[ -s "$POLICY_ORIG" ]] && jq -s '.[0] * .[1]' "$POLICY_ORIG" "$tmp" > "$tmp.merged" 2>/dev/null; then
      mv -- "$tmp.merged" "$tmp"
    fi
    if [[ "$(jq -r '.policies | length' "$tmp")" -gt 0 ]]; then
      as_root install -Dm644 -- "$tmp" "$POLICY_FILE"
      info "Original policies.json restored (only the values this tool wrote were removed)."
    else
      as_root rm -f -- "$POLICY_FILE"
      info "policies.json removed (it did not exist before)."
    fi
    rm -f -- "$tmp"
  fi

  as_root rm -f -- "$POLICY_ORIG"
  newledger="$(printf '%s' "$ledger" | jq -c --arg f "$POLICY_FILE" 'del(.policies[$f])')"
  printf '%s\n' "$newledger" | as_root tee "$SYSTEM_LEDGER" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
if [[ "${LIST_PRESETS:-0}" == "1" ]]; then
  list_presets
  exit 0
fi

resolve_preset

if (( DO_USER )) && [[ $EUID -eq 0 ]]; then
  die "Run as your regular user: the script only asks for sudo when writing policies.json."
fi

if (( REVERT )); then
  if (( DO_USER )); then revert_user; fi
  if (( DO_SYSTEM )); then revert_system; fi
  info "Done. Open Firefox again to load the original state."
elif (( PREVIEW )); then
  if (( DO_SYSTEM )); then preview_policies; fi
  if (( DO_USER )); then preview_user; fi
else
  if (( DO_SYSTEM )); then apply_system; fi
  if (( DO_USER )); then apply_user; fi
  info "Done. Restart Firefox and check about:policies and about:config."
fi