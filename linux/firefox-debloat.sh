#!/usr/bin/env bash
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
#
# Requires: jq.
# On the first run, the existing policies.json is saved as policies.json.debloat-orig. Every run
# writes that original merged with config/, so manual edits to policies.json made after that are
# overwritten (edit config/ or the .debloat-orig instead).
#
# Optional variable: FIREFOX_POLICY_DIR (default: /etc/firefox/policies)

set -euo pipefail

POLICY_DIR="${FIREFOX_POLICY_DIR:-/etc/firefox/policies}"
POLICY_FILE="$POLICY_DIR/policies.json"
POLICY_ORIG="$POLICY_FILE.debloat-orig"   # copy of the original; empty file = there was none
CONFIG_DIR="$(dirname "$(readlink -f "$0")")/../config"
CONFIG_POLICIES="$CONFIG_DIR/policies.json"
CONFIG_USERJS="$CONFIG_DIR/user.js"
MARK_BEGIN='// >>> firefox-debloat >>>'
MARK_END='// <<< firefox-debloat <<<'

DO_USER=1
DO_SYSTEM=1
LOCKED=false
BLOCK_TRANSLATIONS=0
KEEP_SYNC=0
REVERT=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

for arg in "$@"; do
  case "$arg" in
    --user-only)          DO_SYSTEM=0 ;;
    --system-only)        DO_USER=0 ;;
    --lock)               LOCKED=true ;;
    --block-translations) BLOCK_TRANSLATIONS=1 ;;
    --keep-sync)          KEEP_SYNC=1 ;;
    --revert)             REVERT=1 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
  esac
done

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

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
  # Strips CRLF (in case the file was edited on Windows) and, with --keep-sync, the account pref.
  if (( KEEP_SYNC )); then
    sed -e 's/\r$//' -e '/^[[:space:]]*user_pref("identity\.fxaccounts\.enabled",/d' -- "$CONFIG_USERJS"
  else
    sed 's/\r$//' -- "$CONFIG_USERJS"
  fi
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
  local profiles p f running=0 removed
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
}

revert_user() {
  local profiles p f
  if firefox_running; then
    die "Close Firefox before reverting (it rewrites prefs.js on exit)."
  fi
  BLOCK_TRANSLATIONS=1   # makes sure the optional prefs are cleared too
  KEEP_SYNC=0
  mapfile -t profiles < <(find_profiles)
  for p in "${profiles[@]}"; do
    f="$p/user.js"
    # Clears what is in config/ today and what was applied, in case config/ has changed.
    { pref_names; block_pref_names "$f"; } | sort -u | clear_prefs "$p/prefs.js"
    strip_block "$f"
    if [[ -f "$f" ]] && ! grep -q '[^[:space:]]' "$f"; then rm -f -- "$f"; fi
    info "Reverted: $p"
  done
  warn "The block prefs were reset to default, including any you had changed by hand before."
}

# ---------------------------------------------------------------------------------------------
# policies.json
# ---------------------------------------------------------------------------------------------
policies_json() {
  local filter='.'
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
  jq "$filter" "$CONFIG_POLICIES"
}

apply_system() {
  local tmp
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
  rm -f -- "$tmp"
  info "Policies installed at $POLICY_FILE"
}

revert_system() {
  if [[ ! -e "$POLICY_ORIG" ]]; then
    warn "Nothing to revert in $POLICY_DIR (the script was not applied there)."
    return 0
  fi
  if [[ -s "$POLICY_ORIG" ]]; then
    as_root mv -f -- "$POLICY_ORIG" "$POLICY_FILE"
    info "Original policies.json restored."
  else
    as_root rm -f -- "$POLICY_FILE" "$POLICY_ORIG"
    info "policies.json removed (it did not exist before)."
  fi
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
if (( DO_USER )) && [[ $EUID -eq 0 ]]; then
  die "Run as your regular user: the script only asks for sudo when writing policies.json."
fi

if (( REVERT )); then
  if (( DO_USER )); then revert_user; fi
  if (( DO_SYSTEM )); then revert_system; fi
  info "Done. Open Firefox again to load the original state."
else
  if (( DO_SYSTEM )); then apply_system; fi
  if (( DO_USER )); then apply_user; fi
  info "Done. Restart Firefox and check about:policies and about:config."
fi