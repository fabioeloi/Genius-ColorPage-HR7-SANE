#!/bin/bash
set -euo pipefail

readonly PACKAGE_NAME='Genius ColorPage-HR7 SANE'
readonly STATE_DIRECTORY="$HOME/Library/Application Support/GeniusColorPage-HR7-SANE"
readonly CONFIG_DIRECTORY="$STATE_DIRECTORY/config/sane.d"
readonly STATE_FILE="$STATE_DIRECTORY/install-state.txt"
readonly HOMEBREW_INSTALL_URL='https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'

fail() {
    printf '%s\n' "Error: $*" >&2
    exit 1
}

require_supported_host() {
    [[ "$(/usr/bin/uname -s)" == 'Darwin' ]] || fail 'Este instalador exige macOS.'
    [[ "$(/usr/bin/uname -m)" == 'arm64' ]] || fail 'Este instalador exige um Mac Apple Silicon (arm64).'

    local macos_version macos_major
    macos_version="$(/usr/bin/sw_vers -productVersion)"
    macos_major="${macos_version%%.*}"
    [[ "$macos_major" =~ ^[0-9]+$ ]] || fail "Não foi possível interpretar a versão do macOS: $macos_version"
    (( macos_major >= 26 )) || fail "Este instalador exige macOS 26 ou posterior. Detectado: $macos_version"
}

count_hr7_devices() {
    # IORegistry uses decimal numeric values: 0x0458 = 1112 and 0x2013 = 8211.
    # One IOUSBHostDevice record is inspected at a time, so the IDs cannot come
    # from separate USB devices.
    /usr/sbin/ioreg -p IOUSB -l -w 0 -r -c IOUSBHostDevice |
        /usr/bin/awk 'BEGIN { RS="}" } /"idVendor" = 1112/ && /"idProduct" = 8211/ { count++ } END { print count + 0 }'
}

require_one_hr7() {
    local count
    count="$(count_hr7_devices)"
    [[ "$count" == '1' ]] || fail "Conecte diretamente exatamente um Genius ColorPage HR7 (USB 0458:2013). Encontrados: $count"
}

find_brew() {
    if [[ -x /opt/homebrew/bin/brew ]]; then
        printf '%s\n' /opt/homebrew/bin/brew
    elif command -v brew >/dev/null 2>&1; then
        command -v brew
    fi
}

install_homebrew_if_needed() {
    local brew
    brew="$(find_brew || true)"
    if [[ -n "$brew" ]]; then
        printf '%s\n' "$brew"
        return
    fi

    # This function is called in a command substitution. Keep progress output on
    # stderr so that stdout contains only the resolved brew executable path.
    printf '%s\n' 'Homebrew não está instalado.' >&2
    printf '%s\n' "O instalador oficial será obtido de: $HOMEBREW_INSTALL_URL" >&2
    read -r -p 'Digite YES para instalar o Homebrew, ou qualquer outra coisa para cancelar: ' confirmation
    [[ "$confirmation" == 'YES' ]] || fail 'Instalação do Homebrew cancelada.'

    local installer
    installer="$(/usr/bin/curl -fsSL "$HOMEBREW_INSTALL_URL")" || fail 'Não foi possível baixar o instalador oficial do Homebrew.'
    /bin/bash -c "$installer" >&2

    brew="$(find_brew || true)"
    [[ -n "$brew" ]] || fail 'O instalador do Homebrew terminou, mas o comando brew não foi encontrado.'
    printf '%s\n' "$brew"
}

formula_is_installed() {
    local brew="$1" formula="$2"
    "$brew" list --versions "$formula" >/dev/null 2>&1
}

installed_formula_version() {
    local brew="$1" formula="$2"
    "$brew" list --versions "$formula" | /usr/bin/awk 'NR == 1 { print $2 }'
}

require_formula_version() {
    local brew="$1" formula="$2" expected="$3" actual
    actual="$(installed_formula_version "$brew" "$formula")"
    [[ "$actual" == "$expected" || "$actual" == "${expected}_"* ]] || \
        fail "$formula deveria estar na versão $expected, mas está em ${actual:-ausente}. Atualize as fórmulas ou tente novamente mais tarde."
}

write_private_configuration() {
    umask 077
    /bin/mkdir -p "$CONFIG_DIRECTORY"
    /bin/cat > "$CONFIG_DIRECTORY/dll.conf" <<'EOF'
# Private configuration installed by Genius ColorPage-HR7 SANE.
plustek
EOF
    /bin/cat > "$CONFIG_DIRECTORY/plustek.conf" <<'EOF'
# Genius ColorPage HR7 only.
[usb] 0x0458 0x2013
EOF
}

write_state() {
    local brew="$1" sane_was_present="$2" simple_scan_was_present="$3"
    umask 077
    /bin/mkdir -p "$STATE_DIRECTORY"
    /bin/cat > "$STATE_FILE" <<EOF
package=Genius ColorPage-HR7 SANE
installed_at_utc=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
brew_path=$brew
sane_backends_installed_by_package=$([[ "$sane_was_present" == true ]] && printf false || printf true)
simple_scan_installed_by_package=$([[ "$simple_scan_was_present" == true ]] && printf false || printf true)
EOF
}

main() {
    require_supported_host
    require_one_hr7
    [[ ! -e "$STATE_FILE" ]] || fail "Já existe uma instalação registrada em $STATE_FILE. Execute Remove-macOS.command antes de instalar novamente."

    local brew sane_was_present=false simple_scan_was_present=false
    brew="$(install_homebrew_if_needed)"
    if formula_is_installed "$brew" sane-backends; then sane_was_present=true; fi
    if formula_is_installed "$brew" simple-scan; then simple_scan_was_present=true; fi
    # Persist ownership before Homebrew can make a partial installation. That lets
    # Remove-macOS.command safely clean up a failed attempt as well as a complete one.
    write_state "$brew" "$sane_was_present" "$simple_scan_was_present"

    printf '%s\n' 'Instalando sane-backends e simple-scan com Homebrew…'
    "$brew" install sane-backends simple-scan
    require_formula_version "$brew" sane-backends 1.4.0
    require_formula_version "$brew" simple-scan 50.0

    write_private_configuration

    printf '%s\n' 'Instalação concluída.'
    printf '%s\n' 'Execute Diagnose-macOS.command antes da primeira digitalização.'
    printf '%s\n' 'Depois, abra Launch-ColorPage-HR7.command para usar o Simple Scan.'
}

main "$@"
