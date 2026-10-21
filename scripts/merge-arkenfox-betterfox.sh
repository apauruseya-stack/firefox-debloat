#!/usr/bin/env bash
# merge-arkenfox-betterfox.sh
# Layers Arkenfox (privacy) + Betterfox (performance/annoyances) onto a Firefox profile,
# preserving any firefox-debloat managed block.
#
# Pinned upstream versions (update these deliberately, then refresh the checksums):
ARKENFOX_COMMIT="fb56d7bb4ed07898c9d94ca7ecc89697dd88cc3c"
ARKENFOX_SHA256="e4ab33c6914899175cf7035e0e57a2d7f08ac887d8f957f1199e7e49bbe7e33e"
BETTERFOX_COMMIT="067172a4b0dc90e78e5b8b94d9abfe6430c6a7be"
BETTERFOX_SHA256="38a971c7b15225987baf26dd98b884bfb114531b4f6a8f2e0e281fb0352d5240"

set -euo pipefail

ARK_URL="https://raw.githubusercontent.com/arkenfox/user.js/${ARKENFOX_COMMIT}/user.js"
BF_URL="https://raw.githubusercontent.com/yokoffing/Betterfox/${BETTERFOX_COMMIT}/user.js"

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
    # find first profile with prefs.js under common locations
    for base in "$HOME/.mozilla/firefox" "$HOME/.config/mozilla/firefox" "$HOME/.var/app/org.mozilla.firefox/data/mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox"; do
        if [[ -d "$base" ]]; then
            while IFS= read -r -d '' d; do
                if [[ -f "$d/prefs.js" ]]; then PROFILE="$d"; break 2; fi
            done < <(find "$base" -maxdepth 2 -type d -print0 2>/dev/null)
        fi
    done
fi

if [[ -z "$PROFILE" || ! -f "$PROFILE/prefs.js" ]]; then
    echo "No Firefox profile with prefs.js found. Pass the profile path as the first argument." >&2
    exit 1
fi

echo "Profile: $PROFILE"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
ark="$tmpdir/arkenfox-user.js"
bf="$tmpdir/betterfox-user.js"

echo "Downloading pinned Arkenfox (${ARKENFOX_COMMIT:0:12})..."
curl -fsSL "$ARK_URL" -o "$ark"
echo "Downloading pinned Betterfox (${BETTERFOX_COMMIT:0:12})..."
curl -fsSL "$BF_URL" -o "$bf"

verify() {
    local file="$1" expected="$2" name="$3"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        echo "Checksum mismatch for $name!" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        echo "Upstream may have changed. Review before proceeding." >&2
        exit 1
    fi
    echo "  $name checksum OK"
}

verify "$ark" "$ARKENFOX_SHA256" "Arkenfox"
verify "$bf"  "$BETTERFOX_SHA256" "Betterfox"

MARK_BEGIN="// >>> firefox-debloat >>>"
MARK_END="// <<< firefox-debloat <<<"

userjs="$PROFILE/user.js"
block=""
if [[ -f "$userjs" ]]; then
    inblock=0
    while IFS= read -r line; do
        if [[ $inblock -eq 0 && "$line" == "$MARK_BEGIN" ]]; then inblock=1; fi
        if [[ $inblock -eq 1 ]]; then block+="$line"$'\n'; fi
        if [[ $inblock -eq 1 && "$line" == "$MARK_END" ]]; then inblock=0; fi
    done < "$userjs"
fi

backup="$PROFILE/user.js.bak-$(date +%Y%m%d-%H%M%S)"
if [[ -f "$userjs" ]]; then cp "$userjs" "$backup"; echo "Backed up previous user.js to $backup"; fi

{
    cat "$ark"
    echo
    echo "/* ===== BETTERFOX ADDITIONS (Fastfox/Securefox/Peskyfox/Smoothfox) ===== */"
    cat "$bf"
    echo
    if [[ -n "$block" ]]; then
        echo "/* ===== firefox-debloat managed block (kept last so its prefs win) ===== */"
        printf '%s' "$block"
    fi
} > "$userjs"

echo "Merged user.js written to $PROFILE"
echo "Review overrides in overrides/user-overrides.example.js and append if desired."