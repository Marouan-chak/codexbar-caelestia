#!/usr/bin/env bash
# Installs the CodexBar entry into a Caelestia user overlay.
#
# Nothing under /etc/xdg/quickshell/caelestia is written. The overlay at
# ~/.config/quickshell/caelestia gets symlinks to this repo's QML plus two
# patched copies of upstream files; see patches/apply.py.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"

OVERLAY_DIR="${CAELESTIA_OVERLAY:-${CONFIG_HOME}/quickshell/caelestia}"
PACKAGE_DIR="${CAELESTIA_PACKAGE:-/etc/xdg/quickshell/caelestia}"
SHELL_JSON="${CONFIG_HOME}/caelestia/shell.json"

APP_DATA="${DATA_HOME}/codexbar-caelestia"
APP_CONFIG="${CONFIG_HOME}/codexbar-caelestia"

ENABLE_ENTRY=0
ACTION=install

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

  --enable-entry   Also add the "codexUsage" entry to Caelestia's bar order in
                   shell.json, placed just after the clock. Without this the
                   files are installed but the entry stays invisible until you
                   add it yourself (see the README).
  --check          Report whether the install is intact and whether a Caelestia
                   upgrade has moved the files this project patches.
  --uninstall      Remove the QML links and restore the patched files to plain
                   symlinks into the package.
  -h, --help       This message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable-entry) ENABLE_ENTRY=1 ;;
        --check) ACTION=check ;;
        --uninstall) ACTION=uninstall ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }

# --- Dependencies ---------------------------------------------------------
for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed"
done
[[ -d "$PACKAGE_DIR" ]] || die "Caelestia is not installed at $PACKAGE_DIR (set CAELESTIA_PACKAGE)"

if [[ "$ACTION" == "check" ]]; then
    exec python3 "${REPO_DIR}/patches/apply.py" check --overlay "$OVERLAY_DIR" --package "$PACKAGE_DIR" --repo "$REPO_DIR"
fi

if [[ "$ACTION" == "uninstall" ]]; then
    python3 "${REPO_DIR}/patches/apply.py" uninstall --overlay "$OVERLAY_DIR" --package "$PACKAGE_DIR" --repo "$REPO_DIR"
    rm -f "${APP_DATA}/codexbar-usage.sh"
    echo "Removed. The bar entry in shell.json (if any) is left alone."
    exit 0
fi

# --- Locate the codexbar CLI ----------------------------------------------
CODEXBAR="${CODEXBAR_BIN:-}"
if [[ -z "$CODEXBAR" ]]; then
    if [[ -x "${HOME}/.local/bin/codexbar" ]]; then
        CODEXBAR="${HOME}/.local/bin/codexbar"
    else
        CODEXBAR="$(command -v codexbar 2>/dev/null || true)"
    fi
fi
[[ -n "$CODEXBAR" && -x "$CODEXBAR" ]] \
    || die "the codexbar CLI was not found. Install it (see the README) or set CODEXBAR_BIN."
echo "Using the codexbar CLI at $CODEXBAR"

# Reading Antigravity from a running IDE needs a small LD_PRELOAD shim to
# trust its language server's self-signed loopback certificate. Build it now so
# the first bar refresh is not the thing that discovers there is no compiler.
# Not having one is fine: CodexBar falls back to `agy -p /usage` instead.
if grep -q '"antigravity"' "${HOME}/.codexbar/config.json" 2>/dev/null; then
    CC_BIN="$(command -v cc || command -v gcc || command -v clang || true)"
    if [[ -n "$CC_BIN" ]]; then
        mkdir -p "${CACHE_HOME}/codexbar-caelestia"
        if "$CC_BIN" -shared -fPIC -O2 \
            -o "${CACHE_HOME}/codexbar-caelestia/cert_redirect.so" \
            "${REPO_DIR}/scripts/cert_redirect.c" -ldl 2>/dev/null; then
            echo "Built the Antigravity TLS shim"
        else
            echo "warning: could not build the Antigravity TLS shim; usage will come from agy, not the IDE" >&2
        fi
    else
        echo "warning: no C compiler found; Antigravity usage will come from agy, not the IDE" >&2
    fi
fi

# --- Backend script and provider logos ------------------------------------
mkdir -p "$APP_DATA" "$APP_CONFIG"
ln -sfn "${REPO_DIR}/scripts/codexbar-usage.sh" "${APP_DATA}/codexbar-usage.sh"
echo "Linked ${APP_DATA}/codexbar-usage.sh"

mkdir -p "${APP_DATA}/icons"
cp -f "${REPO_DIR}/assets/providers/"*.svg "${APP_DATA}/icons/"
cp -f "${REPO_DIR}/assets/providers/NOTICE" "${APP_DATA}/icons/"
echo "Installed $(find "${APP_DATA}/icons" -name '*.svg' | wc -l) provider logos"

# --- Config ---------------------------------------------------------------
# Keep any settings the user already changed; only fill in the resolved path,
# and drop `codexbarShPath`, which earlier builds used instead.
CONFIG_FILE="${APP_CONFIG}/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    tmp="$(mktemp)"
    jq --arg p "$CODEXBAR" '.codexbarBin = $p | del(.codexbarShPath)' "$CONFIG_FILE" >"$tmp" \
        && mv "$tmp" "$CONFIG_FILE"
    echo "Updated $CONFIG_FILE"
else
    jq -n --arg p "$CODEXBAR" \
        '{codexbarBin: $p, refreshSeconds: 300, showLabels: true, useProviderLogos: true, hiddenProviders: []}' \
        >"$CONFIG_FILE"
    echo "Wrote $CONFIG_FILE"
fi

# --- Overlay ---------------------------------------------------------------
echo "Patching the Caelestia overlay at $OVERLAY_DIR"
python3 "${REPO_DIR}/patches/apply.py" install \
    --overlay "$OVERLAY_DIR" --package "$PACKAGE_DIR" --repo "$REPO_DIR"

# --- Bar order -------------------------------------------------------------
# Caelestia's defaults live in the compiled config plugin, and setting
# bar.entries in shell.json replaces them wholesale rather than merging. So
# when shell.json has no list yet we write the full default order out, with
# codexUsage inserted after the clock. scripts/probe-entries.qml re-derives
# that default from the installed plugin if a Caelestia upgrade changes it.
DEFAULT_ENTRIES='[{"id":"logo","enabled":true},{"id":"workspaces","enabled":true},{"id":"spacer","enabled":true},{"id":"activeWindow","enabled":true},{"id":"spacer","enabled":true},{"id":"tray","enabled":true},{"id":"clock","enabled":true},{"id":"statusIcons","enabled":true},{"id":"power","enabled":true}]'

if [[ "$ENABLE_ENTRY" == "1" ]]; then
    mkdir -p "$(dirname "$SHELL_JSON")"
    [[ -e "$SHELL_JSON" ]] || echo '{}' >"$SHELL_JSON"

    # shell.json is commonly a symlink into a dotfiles repo. Resolve it and
    # edit the real file, so writing here does not replace a managed symlink
    # with a plain file.
    TARGET="$(readlink -f "$SHELL_JSON")"
    [[ -n "$TARGET" && -f "$TARGET" ]] || die "could not resolve $SHELL_JSON"
    jq -e . "$TARGET" >/dev/null 2>&1 || die "$TARGET is not valid JSON; fix it before rerunning"

    BACKUP="${TARGET}.bak-$(date +%s)"
    cp -f "$TARGET" "$BACKUP"

    tmp="$(mktemp)"
    jq --argjson defaults "$DEFAULT_ENTRIES" '
        (.bar.entries // $defaults) as $current
        | ($current | map(.id) | index("clock")) as $i
        | if ($current | map(.id) | index("codexUsage")) then .
          else
            .bar.entries = (
                if $i then
                    $current[0:$i + 1] + [{id: "codexUsage", enabled: true}] + $current[$i + 1:]
                else
                    $current + [{id: "codexUsage", enabled: true}]
                end
            )
          end
    ' "$TARGET" >"$tmp" || { rm -f "$tmp"; die "could not update $TARGET (backup at $BACKUP)"; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "refusing to write invalid JSON to $TARGET"; }
    cat "$tmp" >"$TARGET"
    rm -f "$tmp"
    echo "Added the codexUsage entry to $TARGET (backup at $BACKUP)"
else
    cat <<EOF

The files are in place. To show the entry, add it to bar.entries in
$SHELL_JSON — Caelestia replaces the default order rather than merging, so
list them all:

  "bar": { "entries": $(echo "$DEFAULT_ENTRIES" | jq -c '.[0:7] + [{id:"codexUsage",enabled:true}] + .[7:]') }

Or rerun with --enable-entry to have this script do it.
EOF
fi

cat <<'EOF'

Restart the shell to pick it up:
  caelestia shell -d && caelestia shell -l | grep -iE 'error|warn'
EOF
