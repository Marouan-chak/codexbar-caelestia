#!/usr/bin/env bash
# Fetches CodexBar provider usage and normalises it into the shape the
# Caelestia QML consumes.
#
# Talks to the `codexbar` Linux CLI directly. The CLI does none of the provider
# handling below — the per-provider --source overrides, Claude's OAuth -> CLI
# fallback, the fetch stagger, and the Antigravity credential bridge and TLS
# shim — so this script owns all of it.
#
# Some of that logic is shared verbatim with codexbar-waybar (MIT, same
# author); a fix to the Antigravity paths probably belongs in both.
#
# Output (single line, always valid JSON):
#   {"available":bool,"stale":bool,"error":str|null,"updatedAt":str,
#    "providers":[{"id","name","plan","account","stale","error","maxPercent",
#                  "pace","credits","resetCredits","windows":[...]}]}

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/codexbar-caelestia"
CACHE_FILE="${CACHE_DIR}/last.json"
CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/codexbar-caelestia/config.json"
CODEXBAR_CONFIG="${HOME}/.codexbar/config.json"
mkdir -p "$CACHE_DIR"

fail() {
    # Serve the last good payload if we have one, marked stale, so a transient
    # failure never blanks the bar. Otherwise emit an explicit error object.
    local message="$1"
    if [[ -f "$CACHE_FILE" ]] && jq -e '.available == true' "$CACHE_FILE" >/dev/null 2>&1; then
        jq -c '.stale = true | .providers = [.providers[] | .stale = true]' "$CACHE_FILE"
    else
        jq -cn --arg m "$message" \
            '{available: false, stale: false, error: $m, updatedAt: "", providers: []}'
    fi
    exit 0
}

command -v jq >/dev/null 2>&1 || {
    printf '{"available":false,"stale":false,"error":"jq is not installed","updatedAt":"","providers":[]}\n'
    exit 0
}

# --- Locate the CLI -------------------------------------------------------
CODEXBAR="${CODEXBAR_BIN:-}"
if [[ -z "$CODEXBAR" && -f "$CONFIG_FILE" ]]; then
    CODEXBAR="$(jq -r '.codexbarBin // empty' "$CONFIG_FILE" 2>/dev/null)"
fi
if [[ -z "$CODEXBAR" ]]; then
    if [[ -x "${HOME}/.local/bin/codexbar" ]]; then
        CODEXBAR="${HOME}/.local/bin/codexbar"
    else
        CODEXBAR="$(command -v codexbar 2>/dev/null || true)"
    fi
fi
[[ -n "$CODEXBAR" && -x "$CODEXBAR" ]] || fail "codexbar CLI not found (set codexbarBin)"

# --- Which providers ------------------------------------------------------
# The CLI's own config decides; CODEXBAR_PROVIDERS overrides for testing.
if [[ -n "${CODEXBAR_PROVIDERS:-}" ]]; then
    # shellcheck disable=SC2206
    PROVIDERS=( ${CODEXBAR_PROVIDERS} )
elif [[ -f "$CODEXBAR_CONFIG" ]]; then
    readarray -t PROVIDERS < <(jq -r '[.providers[]? | select(.enabled == true) | .id] | .[]' "$CODEXBAR_CONFIG" 2>/dev/null)
    [[ ${#PROVIDERS[@]} -eq 0 ]] && PROVIDERS=(codex)
else
    PROVIDERS=(codex)
fi

# Codex and Claude need an explicit oauth source on Linux: their `auto` tries
# the web source first, which is macOS-only.
declare -A SOURCE_OVERRIDES=([codex]=oauth [claude]=oauth)
# Claude's OAuth endpoint rate-limits; its local CLI logs carry the same
# windowing data, so retry there on a provider-level error.
declare -A FALLBACK_SOURCES=([claude]=cli)

STAGGER_SECS="${CODEXBAR_STAGGER:-0.5}"
PROVIDER_TIMEOUT_SECS="${CODEXBAR_PROVIDER_TIMEOUT:-20}"

# --- Antigravity ----------------------------------------------------------
# The CLI reads quotas from a running IDE's language server, or else from
# `agy -p /usage`, and needs no credentials for either. OAuth creds are opt-in
# only: injecting them makes the CLI skip the `agy` report, and on Linux the
# OAuth source cannot refresh a token without ANTIGRAVITY_OAUTH_CLIENT_ID and
# ANTIGRAVITY_OAUTH_CLIENT_SECRET, so a stale token silently broke the ring.
ANTIGRAVITY_CREDS="${CODEXBAR_ANTIGRAVITY_CREDS:-}"
ANTIGRAVITY_CUSTOM_CA_BUNDLE=""
ANTIGRAVITY_LD_PRELOAD=""

# Build the CA-redirect shim on demand. Absence of a compiler is not fatal:
# Antigravity will report a provider error and every other ring keeps working.
build_cert_shim() {
    local src="${SCRIPT_DIR}/cert_redirect.c"
    local so="${CACHE_DIR}/cert_redirect.so"
    [[ -f "$src" ]] || return 1
    if [[ -f "$so" && "$so" -nt "$src" ]]; then
        printf '%s' "$so"
        return 0
    fi
    local cc
    cc="$(command -v cc || command -v gcc || command -v clang || true)"
    [[ -n "$cc" ]] || return 1
    "$cc" -shared -fPIC -O2 -o "$so" "$src" -ldl 2>/dev/null || return 1
    printf '%s' "$so"
}

# Extract the language server's self-signed cert and append it to a private
# copy of the system CA bundle, so only the CLI process trusts it.
setup_antigravity_ssl() {
    command -v openssl >/dev/null 2>&1 || return 1
    command -v lsof >/dev/null 2>&1 || return 1
    command -v pgrep >/dev/null 2>&1 || return 1

    local pid
    pid=$(pgrep -f "Antigravity.*/language_server" | head -n 1)
    [[ -n "$pid" ]] || return 1

    local ports
    ports=$(lsof -a -p "$pid" -iTCP -sTCP:LISTEN -F n 2>/dev/null | grep -oE '[0-9]+$')
    [[ -n "$ports" ]] || return 1

    local cert="" out port
    for port in $ports; do
        out=$(openssl s_client -showcerts -connect 127.0.0.1:"$port" </dev/null 2>/dev/null)
        if [[ "$out" == *"-----BEGIN CERTIFICATE-----"* ]]; then
            cert=$(echo "$out" | openssl x509 -outform PEM 2>/dev/null)
            [[ -n "$cert" ]] && break
        fi
    done
    [[ -n "$cert" ]] || return 1

    local so
    so="$(build_cert_shim)" || return 1

    local scratch_dir="${CACHE_DIR}/scratch"
    mkdir -p "$scratch_dir"
    local cert_file="${scratch_dir}/localhost.crt"
    printf '%s\n' "$cert" >"$cert_file"

    local sys_ca="" path
    for path in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
                /etc/ssl/ca-bundle.pem /var/lib/ca-certificates/ca-bundle.pem; do
        [[ -f "$path" ]] && { sys_ca="$path"; break; }
    done

    local bundle_file="${scratch_dir}/custom-ca-bundle.crt"
    if [[ -n "$sys_ca" ]]; then
        cat "$sys_ca" "$cert_file" >"$bundle_file"
    else
        cat "$cert_file" >"$bundle_file"
    fi

    ANTIGRAVITY_CUSTOM_CA_BUNDLE="$bundle_file"
    ANTIGRAVITY_LD_PRELOAD="$so"
    return 0
}

if [[ " ${PROVIDERS[*]} " == *" antigravity "* ]]; then
    setup_antigravity_ssl || true
fi

# --- Fetch ----------------------------------------------------------------
fetch_one() {
    local p="$1" src="$2"
    local args=(usage --provider "$p" --format json --no-color)
    [[ -n "$src" ]] && args+=(--source "$src")

    local runner=()
    if [[ "$PROVIDER_TIMEOUT_SECS" != "0" ]] && command -v timeout >/dev/null 2>&1; then
        runner=(timeout "$PROVIDER_TIMEOUT_SECS")
    fi

    if [[ "$p" == "antigravity" ]]; then
        local env_args=(
            CUSTOM_CA_BUNDLE="$ANTIGRAVITY_CUSTOM_CA_BUNDLE"
            LD_PRELOAD="$ANTIGRAVITY_LD_PRELOAD"
        )
        if [[ -z "${ANTIGRAVITY_OAUTH_CREDENTIALS_JSON:-}" && -f "$ANTIGRAVITY_CREDS" ]]; then
            env_args+=(ANTIGRAVITY_OAUTH_CREDENTIALS_JSON="$(cat "$ANTIGRAVITY_CREDS")")
        fi
        "${runner[@]}" env "${env_args[@]}" "$CODEXBAR" "${args[@]}" 2>/dev/null
        return
    fi

    "${runner[@]}" "$CODEXBAR" "${args[@]}" 2>/dev/null
}

fetch_provider() {
    local p="$1"
    local body fallback_body
    body="$(fetch_one "$p" "${SOURCE_OVERRIDES[$p]:-}")"

    # Only retry when the response is a well-formed array carrying a
    # provider-level error; network blips and rate limits land there.
    local fallback="${FALLBACK_SOURCES[$p]:-}"
    if [[ -n "$fallback" ]] \
        && echo "$body" | jq -e 'type == "array" and (.[0].error // null) != null' >/dev/null 2>&1; then
        fallback_body="$(fetch_one "$p" "$fallback")"
        if echo "$fallback_body" | jq -e 'type == "array"' >/dev/null 2>&1; then
            body="$fallback_body"
        fi
    fi
    echo "$body"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

# Sequential with a stagger; parallel fetches trip per-provider rate limits.
i=0
for p in "${PROVIDERS[@]}"; do
    (( i > 0 )) && sleep "$STAGGER_SECS"
    fetch_provider "$p" >"$tmpdir/$p.json"
    i=$((i + 1))
done

merged="["
first=1
for p in "${PROVIDERS[@]}"; do
    body="$(cat "$tmpdir/$p.json")"
    entries=""
    if [[ -z "$body" ]] || ! echo "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then
        entries="$(jq -cn --arg provider "$p" \
            '{provider: $provider, error: {message: "no usable response from the codexbar CLI"}}')"
    else
        entries="$(echo "$body" | jq -c '.[]')"
    fi
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if (( first )); then
            merged+="$entry"
            first=0
        else
            merged+=",$entry"
        fi
    done <<<"$entries"
done
merged+="]"

[[ "$merged" != "[]" ]] || fail "no provider data"

# --- Normalise ------------------------------------------------------------
normalised="$(echo "$merged" | jq -c --arg now "$(date -u +%FT%TZ)" '
    def provider_name(p):
        if p == null then "Unknown" else
        {
          antigravity: "Antigravity", augment: "Augment", bedrock: "Bedrock",
          chutes: "Chutes", claude: "Claude", codex: "Codex",
          copilot: "Copilot", cursor: "Cursor", deepseek: "DeepSeek",
          factory: "Factory", gemini: "Gemini", glm: "GLM", grok: "Grok",
          groq: "Groq", kimi: "Kimi", minimax: "MiniMax", mistral: "Mistral",
          openrouter: "OpenRouter", perplexity: "Perplexity", qwen: "Qwen",
          sakana: "Sakana", together: "Together", vercel: "Vercel",
          warp: "Warp", windsurf: "Windsurf", zai: "Z.ai"
        }[p] // (p[0:1] | ascii_upcase) + p[1:]
        end;

    # Human label for an unnamed window, keyed on its length. Claude calls its
    # weekly window "All models" in the upstream macOS UI; keep that wording.
    def window_label(mins; p; slot):
        if mins == 300 then "Current session"
        elif mins == 10080 then (if p == "claude" then "All models" else "Weekly" end)
        elif mins == 1440 then "Daily"
        elif mins == 60 then "Hourly"
        elif mins == null or mins == 0 then
            {primary: "Session", secondary: "Weekly", tertiary: "Extra"}[slot] // "Usage"
        elif mins < 60 then "\(mins)m window"
        else "\((mins / 60) | floor)h window"
        end;

    def as_window(w; lbl):
        if w == null or (w.usedPercent == null) or (w.usageKnown? == false) then empty
        else {
            label: lbl,
            usedPercent: (w.usedPercent | if . < 0 then 0 else . end),
            resetDescription: (w.resetDescription // null),
            resetsAt: (w.resetsAt // null),
            windowMinutes: (w.windowMinutes // null)
        } end;

    map(
        .provider as $p
        | .usage as $u
        | {
            id: ($p // "unknown"),
            name: provider_name($p),
            plan: ($u.plan // $u.loginMethod // $u.identity.loginMethod // null),
            account: (.account // null),
            source: (.source // null),
            stale: (.stale == true),
            # "offline" is the CLI giving up on live data and reporting no
            # quota, so it is a failure: that is what lets the cached
            # snapshot stand in rather than a ring stuck at 0%.
            error: (.error.message // .error
                    // (if .source == "offline" then (.diagnostic // "live usage is unavailable") else null end)),
            maxPercent: (
                [$u.primary.usedPercent, $u.secondary.usedPercent, $u.tertiary.usedPercent]
                | map(select(type == "number")) | max // null
            ),
            pace: (.pace.secondary.summary // .pace.primary.summary // null),
            credits: (.credits.remaining // null),
            resetCredits: ($u.codexResetCredits.availableCount // null),
            windows: [
                as_window($u.primary;   window_label($u.primary.windowMinutes;   $p; "primary")),
                as_window($u.secondary; window_label($u.secondary.windowMinutes; $p; "secondary")),
                as_window($u.tertiary;  window_label($u.tertiary.windowMinutes;  $p; "tertiary")),
                ($u.extraRateWindows[]? | select(.usageKnown != false) | as_window(.window; (.title // "Extra")))
            ]
        }
    )
    | {
        available: (map(select(.error == null)) | length > 0),
        stale: (map(.stale) | any),
        error: null,
        updatedAt: $now,
        providers: .
    }
')"

[[ -n "$normalised" ]] || fail "could not normalise the codexbar CLI output"

# Serve the previous snapshot for any provider that failed this round, so a
# single provider's 429 does not blank its ring.
if [[ -f "$CACHE_FILE" ]] && jq -e '.providers' "$CACHE_FILE" >/dev/null 2>&1; then
    normalised="$(jq -c --slurpfile prev "$CACHE_FILE" '
        ([$prev[0].providers[]? | select(.error == null) | {key: .id, value: .}] | from_entries) as $ok
        | .providers = [
            .providers[]
            | if .error != null and $ok[.id] then $ok[.id] + {stale: true} else . end
          ]
        | .available = ([.providers[] | select(.error == null)] | length > 0)
        | .stale = ([.providers[] | .stale] | any)
    ' <<<"$normalised")"
fi

# Persist per provider, never wholesale. Writing the payload as-is would let a
# provider that is merely broken right now overwrite the last good snapshot of
# itself, after which the fallback above has nothing left to fall back to.
if [[ -n "$normalised" ]]; then
    tmp="$(mktemp "${CACHE_DIR}/last.XXXXXX")"
    if [[ -f "$CACHE_FILE" ]] && jq -e '.providers' "$CACHE_FILE" >/dev/null 2>&1; then
        jq -c --slurpfile prev "$CACHE_FILE" '
            ([$prev[0].providers[]? | select(.error == null) | {key: .id, value: .}] | from_entries) as $old
            | .providers = [
                .providers[]
                | if .error == null then . else ($old[.id] // .) end
              ]
        ' <<<"$normalised" >"$tmp"
    else
        printf '%s\n' "$normalised" >"$tmp"
    fi
    if jq -e '.providers' "$tmp" >/dev/null 2>&1; then
        chmod 600 "$tmp"
        mv "$tmp" "$CACHE_FILE"
    else
        rm -f "$tmp"
    fi
fi

printf '%s\n' "$normalised"
