#!/bin/bash
set -euo pipefail

readonly STATE_DIRECTORY="$HOME/Library/Application Support/GeniusColorPage-HR7-SANE"
readonly CONFIG_DIRECTORY="$STATE_DIRECTORY/config/sane.d"
readonly LOG_DIRECTORY="$STATE_DIRECTORY/logs"

fail() {
    printf '%s\n' "Error: $*" >&2
    exit 1
}

count_hr7_devices() {
    /usr/sbin/ioreg -p IOUSB -l -w 0 -r -c IOUSBHostDevice |
        /usr/bin/awk 'BEGIN { RS="}" } /"idVendor" = 1112/ && /"idProduct" = 8211/ { count++ } END { print count + 0 }'
}

find_brew() {
    if [[ -x /opt/homebrew/bin/brew ]]; then
        printf '%s\n' /opt/homebrew/bin/brew
    elif command -v brew >/dev/null 2>&1; then
        command -v brew
    fi
}

[[ -d "$CONFIG_DIRECTORY" ]] || fail 'Instalação ausente ou incompleta. Execute Install-macOS.command primeiro.'
brew="$(find_brew || true)"
[[ -n "$brew" ]] || fail 'Homebrew não foi encontrado.'
sane_prefix="$("$brew" --prefix sane-backends)"
[[ -x "$sane_prefix/bin/scanimage" && -x "$sane_prefix/bin/sane-find-scanner" ]] || \
    fail 'sane-backends não está instalado corretamente.'

umask 077
/bin/mkdir -p "$LOG_DIRECTORY"
log_path="$LOG_DIRECTORY/diagnose-$(/bin/date -u +%Y%m%d-%H%M%S).log"
hr7_count="$(count_hr7_devices)"

{
    printf 'Timestamp UTC: %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'macOS: %s; architecture: %s\n' "$(/usr/bin/sw_vers -productVersion)" "$(/usr/bin/uname -m)"
    printf 'Expected USB ID: 0458:2013\n'
    printf 'Detected matching USB devices: %s\n' "$hr7_count"
    printf '\n== sane-find-scanner -v ==\n'
    SANE_CONFIG_DIR="$CONFIG_DIRECTORY" "$sane_prefix/bin/sane-find-scanner" -v 2>&1 || true
    printf '\n== scanimage -L ==\n'
    SANE_CONFIG_DIR="$CONFIG_DIRECTORY" "$sane_prefix/bin/scanimage" -L 2>&1 || true
} > "$log_path"

/bin/cat "$log_path"
[[ "$hr7_count" == '1' ]] || fail "O log foi salvo em $log_path, mas exatamente um HR7 deve estar conectado. Encontrados: $hr7_count"
