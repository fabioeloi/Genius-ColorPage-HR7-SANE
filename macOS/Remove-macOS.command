#!/bin/bash
set -euo pipefail

readonly STATE_DIRECTORY="$HOME/Library/Application Support/GeniusColorPage-HR7-SANE"
readonly STATE_FILE="$STATE_DIRECTORY/install-state.txt"
readonly STATE_PARENT="$HOME/Library/Application Support"

fail() {
    printf '%s\n' "Error: $*" >&2
    exit 1
}

state_value() {
    local key="$1"
    /usr/bin/awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$STATE_FILE"
}

find_brew() {
    if [[ -x /opt/homebrew/bin/brew ]]; then
        printf '%s\n' /opt/homebrew/bin/brew
    elif command -v brew >/dev/null 2>&1; then
        command -v brew
    fi
}

remove_brew_packages=false
if [[ "${1:-}" == '--remove-brew-packages' ]]; then
    remove_brew_packages=true
    shift
fi
[[ "$#" == 0 ]] || fail 'Uso: ./Remove-macOS.command [--remove-brew-packages]'

[[ -f "$STATE_FILE" ]] || fail 'Instalação registrada não foi encontrada.'
[[ "$STATE_DIRECTORY" == "$STATE_PARENT/GeniusColorPage-HR7-SANE" ]] || \
    fail 'O caminho de estado não passou na validação de segurança.'

if [[ "$remove_brew_packages" == true ]]; then
    brew="$(find_brew || true)"
    [[ -n "$brew" ]] || fail 'Homebrew não foi encontrado para remover os pacotes solicitados.'

    if [[ "$(state_value simple_scan_installed_by_package)" == true ]] && "$brew" list --versions simple-scan >/dev/null 2>&1; then
        "$brew" uninstall simple-scan
    fi
    if [[ "$(state_value sane_backends_installed_by_package)" == true ]] && "$brew" list --versions sane-backends >/dev/null 2>&1; then
        "$brew" uninstall sane-backends
    fi
fi

/bin/rm -rf "$STATE_DIRECTORY"
printf '%s\n' 'Configuração, logs e estado locais foram removidos.'
if [[ "$remove_brew_packages" == true ]]; then
    printf '%s\n' 'Somente fórmulas instaladas por este pacote foram removidas do Homebrew.'
else
    printf '%s\n' 'As fórmulas Homebrew foram preservadas. Use --remove-brew-packages somente se não forem usadas por outro scanner.'
fi
