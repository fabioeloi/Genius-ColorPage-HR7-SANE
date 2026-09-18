#!/bin/bash
set -euo pipefail

readonly STATE_DIRECTORY="$HOME/Library/Application Support/GeniusColorPage-HR7-SANE"
readonly CONFIG_DIRECTORY="$STATE_DIRECTORY/config/sane.d"

fail() {
    printf '%s\n' "Error: $*" >&2
    exit 1
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
simple_scan="$("$brew" --prefix simple-scan)/bin/simple-scan"
[[ -x "$sane_prefix/bin/scanimage" && -x "$simple_scan" ]] || \
    fail 'sane-backends ou Simple Scan não está instalado corretamente. Execute Diagnose-macOS.command.'

export PATH="$sane_prefix/bin:$PATH"
export SANE_CONFIG_DIR="$CONFIG_DIRECTORY"
exec "$simple_scan"
