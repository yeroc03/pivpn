#!/bin/bash
# PiVPN setup menu: PiVPN itself and its extras from one place.
#
#   PiVPN         the PiVPN installer (WireGuard / OpenVPN)
#   DuckDNS       extras/duckdns-update/setup.sh
#   Proton Drive  extras/proton-drive-sync/setup.sh
#   Tailscale     extras/tailscale/setup.sh
#
# ./install.sh opens this menu when it runs in a terminal without options.
# Each item shows whether it is set up; choosing it again changes its
# settings. Run it as your normal user: the PiVPN installer and the extras
# use sudo themselves.

# shellcheck source-path=SCRIPTDIR
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
TOP_DIR="${SCRIPT_DIR%/*}"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

set -o nounset

BACKTITLE="PiVPN Setup"

# Set by the PiVPN installer when it hands over to this menu after an install
REBOOT_PENDING="${PIVPN_REBOOT_PENDING:-}"

### Status lines (no root needed)

statusPiVPN() {
  local protocols

  protocols="$(pivpnProtocols)"

  if [[ -n "${protocols}" ]]; then
    echo "VPN server: ${protocols}"
  else
    echo "VPN server: install WireGuard or OpenVPN"
  fi
}

statusDuckDNS() {
  if ! systemctl is-enabled --quiet duckdns-update.timer 2> /dev/null; then
    echo "Dynamic DNS for your home IP: not set up"
  elif systemctl is-failed --quiet duckdns-update.service 2> /dev/null; then
    echo "Dynamic DNS: on, last update FAILED"
  else
    echo "Dynamic DNS: on, every 5 minutes"
  fi
}

# The user whose profiles are synced, from the enabled path unit
protonUser() {
  local unit user

  for unit in /etc/systemd/system/paths.target.wants/pivpn-proton-sync@*.path; do
    [[ -e "${unit}" || -L "${unit}" ]] || continue
    user="${unit##*@}"
    echo "${user%.path}"
    return 0
  done

  return 1
}

statusProton() {
  local user

  if ! user="$(protonUser)"; then
    echo "Copy profiles to Proton Drive: not set up"
  elif systemctl is-failed --quiet "pivpn-proton-sync@${user}.service" 2> /dev/null; then
    echo "Profile sync: on, last sync FAILED"
  else
    echo "Profile sync: on (${user})"
  fi
}

tailscaleState() {
  want tailscale || return 1
  timeout 5 tailscale status --json 2> /dev/null \
    | grep -o '"BackendState": *"[A-Za-z]*"' | head -n 1 | grep -o '[A-Za-z]*"$' \
    | tr -d '"'
}

statusTailscale() {
  local state

  if ! want tailscale; then
    echo "Tailnet, exit node, subnet router: not set up"
    return 0
  fi

  state="$(tailscaleState)"

  case "${state}" in
    Running) echo "Tailnet: connected" ;;
    NeedsLogin | NoState) echo "Tailnet: installed, not signed in" ;;
    NeedsMachineAuth) echo "Tailnet: waiting for device approval" ;;
    Stopped) echo "Tailnet: signed in, stopped" ;;
    *) echo "Tailnet: installed, tailscaled not running" ;;
  esac
}

# The first item that isn't set up yet, to put the cursor on
nextItem() {
  if [[ -z "$(pivpnProtocols)" ]]; then
    echo "PiVPN"
  elif ! systemctl is-enabled --quiet duckdns-update.timer 2> /dev/null; then
    echo "DuckDNS"
  elif ! protonUser > /dev/null; then
    echo "Proton Drive"
  elif [[ "$(tailscaleState)" != "Running" ]]; then
    echo "Tailscale"
  else
    echo "Exit"
  fi
}

### Running the items

# runItem <name> <command>...: run one item, and pause on errors so their
# output can be read before the menu covers it
runItem() {
  local name="$1" rc
  shift

  clear 2> /dev/null
  "$@"
  rc=$?

  if [[ "${rc}" -ne 0 && "${rc}" -ne "${EXIT_CANCELLED}" ]]; then
    echo
    log "${name} ended with an error (exit status ${rc}), see above."
    read -r -p "::: Press Enter to return to the menu. " _
  fi

  return "${rc}"
}

# Modification times of PiVPN's settings: they change with every install,
# repair or reconfiguration (the cue to reboot)
pivpnStamp() {
  stat -c '%n %Y' /etc/pivpn/*/setupVars.conf 2> /dev/null
}

runPiVPN() {
  local before

  before="$(pivpnStamp)"
  # PIVPN_SETUP_MENU: the installer returns here instead of offering a reboot
  runItem "The PiVPN installer" \
    env PIVPN_SETUP_MENU=1 bash "${TOP_DIR}/auto_install/install.sh"

  [[ "$(pivpnStamp)" != "${before}" ]] && REBOOT_PENDING=1
}

offerReboot() {
  [[ -n "${REBOOT_PENDING}" ]] || return 0

  if ask --no --yes-button "Reboot" --no-button "Later" "Reboot" "PiVPN was \
installed or reconfigured. It is strongly recommended to reboot now.

Reboot this machine now?"; then
    log "Rebooting..."

    if root; then
      reboot
    else
      sudo reboot
    fi
  fi
}

main() {
  local choice address

  needTerminal
  needWhiptail
  address="$(lanAddress)"

  while true; do
    choose choice --default "$(nextItem)" --cancel "Exit" "PiVPN Setup" \
      "Set up this machine as your home VPN gateway. Choose an item to set \
it up, or to change its settings when it is already set up.

Machine: $(hostname -s)${address:+ (${address})}" \
      "PiVPN" "$(statusPiVPN)" \
      "DuckDNS" "$(statusDuckDNS)" \
      "Proton Drive" "$(statusProton)" \
      "Tailscale" "$(statusTailscale)" \
      "Exit" "Leave the setup" || break

    case "${choice}" in
      PiVPN)
        runPiVPN
        ;;
      DuckDNS)
        runItem "The DuckDNS setup" bash "${SCRIPT_DIR}/duckdns-update/setup.sh"
        ;;
      "Proton Drive")
        runItem "The Proton Drive setup" \
          bash "${SCRIPT_DIR}/proton-drive-sync/setup.sh"
        ;;
      Tailscale)
        runItem "The Tailscale setup" bash "${SCRIPT_DIR}/tailscale/setup.sh"
        ;;
      *)
        break
        ;;
    esac
  done

  clear 2> /dev/null
  offerReboot
  log "To come back to this menu later: ${TOP_DIR}/install.sh"
}

main "$@"
