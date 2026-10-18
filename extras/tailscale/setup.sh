#!/bin/bash
# Guided setup of Tailscale on the PiVPN machine (extras/tailscale).
#
# Installs Tailscale from its official package repository (if needed), asks
# what the machine should do in your tailnet (exit node, subnet router for
# your LAN, Tailscale SSH, tailnet DNS), turns on IP forwarding when routing,
# and signs the machine in with a link/QR code or an auth key. Run it again to
# change the roles; the current ones are preselected.
#
#   extras/tailscale/setup.sh     (or: ./install.sh in the clone, then Tailscale)
#
# Runs itself with sudo when started as a normal user.

# shellcheck source-path=SCRIPTDIR
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

set -o nounset

BACKTITLE="PiVPN Setup - Tailscale"
SETUP_NAME="Tailscale setup"

TS_PKGS_URL="${TS_PKGS_URL:-https://pkgs.tailscale.com/stable}"
TS_KEYRING="/usr/share/keyrings/tailscale-archive-keyring.gpg"
TS_SOURCES="/etc/apt/sources.list.d/tailscale.list"
SYSCTL_FILE="/etc/sysctl.d/99-tailscale.conf"
ADMIN_URL="https://login.tailscale.com/admin/machines"

INSTALLED=0
TS_VERSION=""
STATE="" # tailscaled's BackendState, empty when not running
SIGNED_IN=0
TAILNET=""

# Choices
EXIT_NODE=0
SUBNET=0
TS_SSH=0
TS_DNS=0
ROUTES=""
AUTH="link" # link or key
AUTH_KEY=""

### Helpers

# tsStatus: 'tailscale status --json', or nothing when tailscaled isn't up
tsStatus() {
  timeout 10 tailscale status --json 2> /dev/null
}

readState() {
  local json

  INSTALLED=0
  STATE=""
  SIGNED_IN=0
  TAILNET=""
  want tailscale || return 0

  INSTALLED=1
  TS_VERSION="$(tailscale version 2> /dev/null | head -n 1)"
  json="$(tsStatus)" || return 0
  STATE="$(jq -r '.BackendState // empty' <<< "${json}")"
  TAILNET="$(jq -r '.CurrentTailnet.Name // empty' <<< "${json}")"

  case "${STATE}" in
    Running | Starting | NeedsMachineAuth | Stopped) SIGNED_IN=1 ;;
  esac
}

# Preselect the roles from the current settings (or from the usual choice
# for this machine on a fresh install)
loadPrefs() {
  local prefs routes

  if [[ "${SIGNED_IN}" -eq 0 ]] \
    || ! prefs="$(timeout 10 tailscale debug prefs 2> /dev/null)"; then
    EXIT_NODE=1
    SUBNET=1
    TS_SSH=0
    TS_DNS=0
    ROUTES="$(lanCidr)"
    return 0
  fi

  routes="$(jq -r '(.AdvertiseRoutes // [])[]' <<< "${prefs}")"
  grep -qx '0.0.0.0/0' <<< "${routes}" && EXIT_NODE=1
  ROUTES="$(grep -vx -e '0.0.0.0/0' -e '::/0' <<< "${routes}" | paste -sd ',')"
  [[ -n "${ROUTES}" ]] && SUBNET=1
  [[ "$(jq -r '.RunSSH // false' <<< "${prefs}")" == "true" ]] && TS_SSH=1
  [[ "$(jq -r '.CorpDNS // false' <<< "${prefs}")" == "true" ]] && TS_DNS=1
  [[ -z "${ROUTES}" ]] && ROUTES="$(lanCidr)"
}

onOff() {
  [[ "$1" -eq 1 ]] && echo ON || echo OFF
}

yesNo() {
  [[ "$1" -eq 1 ]] && echo true || echo false
}

# distro and codename for pkgs.tailscale.com: "ubuntu resolute"
repoTarget() {
  local id codename

  # shellcheck disable=SC1091
  id="$(. /etc/os-release && echo "${ID:-}")"
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"

  case "${id}" in
    ubuntu | debian | raspbian) ;;
    *) return 1 ;;
  esac

  [[ -n "${codename}" ]] || return 1
  echo "${id} ${codename}"
}

### Steps

stepIntro() {
  local text

  text="Tailscale connects this machine to your tailnet, your private \
network of devices signed in to the same Tailscale account. It works without \
port forwarding, next to PiVPN's WireGuard and OpenVPN.

This machine can also be:
  - an exit node: your devices browse through your home
  - a subnet router: your devices reach the LAN (NAS,
    Proxmox, printers) without Tailscale on each of them

You choose on the next screen, then sign in with a link or an auth key."

  if [[ "${INSTALLED}" -eq 1 ]]; then
    text+="

Tailscale ${TS_VERSION} is installed"
    if [[ "${SIGNED_IN}" -eq 1 ]]; then
      text+=" and signed in${TAILNET:+ (tailnet ${TAILNET})}. Continue to \
change its roles."
    else
      text+=" but not signed in."
    fi
  fi

  ask --yes-button "Continue" --no-button "Cancel" "Tailscale" "${text}"
}

stepRoles() {
  local chosen dnsServer

  dnsServer="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2> /dev/null)"
  [[ "${dnsServer}" == 127.0.0.* ]] \
    && dnsServer="$(resolvectl dns 2> /dev/null | awk '$NF ~ /^[0-9.]+$/ {print $NF; exit}')"

  checklist chosen "What this machine does" "Choose what this machine \
offers your tailnet (space toggles, Enter confirms). With nothing ticked it \
just joins the tailnet.

Exit node and subnet router together are the usual choice for a VPN \
machine. Leave tailnet DNS off to keep using your own DNS server\
${dnsServer:+ (${dnsServer})}." \
    "exit" "Exit node (route devices' internet traffic)" "$(onOff "${EXIT_NODE}")" \
    "subnet" "Subnet router (reach your LAN from the tailnet)" "$(onOff "${SUBNET}")" \
    "ssh" "Tailscale SSH to this machine" "$(onOff "${TS_SSH}")" \
    "dns" "Use the tailnet's DNS (MagicDNS) here" "$(onOff "${TS_DNS}")" \
    || return 1

  EXIT_NODE=0
  SUBNET=0
  TS_SSH=0
  TS_DNS=0
  grep -qx exit <<< "${chosen}" && EXIT_NODE=1
  grep -qx subnet <<< "${chosen}" && SUBNET=1
  grep -qx ssh <<< "${chosen}" && TS_SSH=1
  grep -qx dns <<< "${chosen}" && TS_DNS=1

  return 0
}

stepRoutes() {
  local value part parts clean=() bad="" dev

  [[ "${SUBNET}" -eq 1 ]] || return 0

  dev="$(lanInterface)"
  value="${ROUTES:-$(lanCidr)}"

  while true; do
    input value "Subnet routes" "The networks your tailnet devices may \
reach through this machine, comma separated. Usually just your LAN.

Detected LAN: $(lanCidr || echo unknown)${dev:+ on ${dev}}" "${value}" \
      || return 1

    value="${value//[[:space:]]/}"
    clean=()
    bad=""
    IFS=',' read -r -a parts <<< "${value}"

    for part in "${parts[@]}"; do
      [[ -z "${part}" ]] && continue

      if [[ "${part}" == "0.0.0.0/0" || "${part}" == "::/0" ]]; then
        bad="${part} is the whole internet: tick Exit node for that instead"
      elif validCidr4 "${part}"; then
        part="$(networkOf "${part}")"
        [[ " ${clean[*]} " == *" ${part} "* ]] || clean+=("${part}")
      elif [[ "${part}" =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]*/[0-9]{1,3}$ ]]; then
        [[ " ${clean[*]} " == *" ${part,,} "* ]] || clean+=("${part,,}")
      else
        bad="\"${part}\" is not a network in CIDR form, such as 192.168.1.0/24"
      fi
    done

    if [[ -n "${bad}" ]]; then
      msg "Subnet routes" "${bad}."
    elif [[ "${#clean[@]}" -eq 0 ]]; then
      msg "Subnet routes" "Enter at least one network, such as \
$(lanCidr || echo 192.168.1.0/24)."
    else
      ROUTES="$(
        IFS=,
        echo "${clean[*]}"
      )"
      return 0
    fi
  done
}

stepAuth() {
  local choice value

  [[ "${SIGNED_IN}" -eq 1 ]] && return 0

  choose choice --default "${AUTH}" "Sign in to Tailscale" "How should this \
machine sign in to your tailnet?

An auth key is made in the admin console: Settings, Keys, Generate auth \
key." \
    "link" "Sign in with a link or QR code, on any device" \
    "key" "Paste an auth key (tskey-auth-...)" || return 1

  AUTH="${choice}"
  [[ "${AUTH}" == "key" ]] || return 0

  while true; do
    secret value "Tailscale auth key" "Paste the auth key (it starts with \
tskey-). It stays hidden while you type, and it is only passed to Tailscale \
through a temporary root-only file." || return 1
    value="${value//[[:space:]]/}"

    if [[ "${value}" =~ ^tskey-[A-Za-z0-9_-]+$ ]]; then
      AUTH_KEY="${value}"
      return 0
    fi

    msg "Tailscale auth key" "That is not a Tailscale auth key: they start \
with tskey- and contain only letters, digits and dashes."
  done
}

stepConfirm() {
  local text installLine target routing="" signInLine

  if [[ "${INSTALLED}" -eq 1 ]]; then
    installLine="installed (${TS_VERSION})"
  else
    target="$(repoTarget)" \
      || die "There are no Tailscale packages for this system in the setup's \
list (Ubuntu, Debian and Raspberry Pi OS are supported). See \
https://tailscale.com/download/linux"
    installLine="from pkgs.tailscale.com (${target})"
  fi

  if [[ "${SIGNED_IN}" -eq 1 ]]; then
    signInLine="already signed in${TAILNET:+ (${TAILNET})}"
  elif [[ "${AUTH}" == "key" ]]; then
    signInLine="auth key $(tail4 "${AUTH_KEY}")"
  else
    signInLine="link or QR code, shown in the next step"
  fi

  text="Ready to set up Tailscale:

  Tailscale:      ${installLine}
  Exit node:      $([[ "${EXIT_NODE}" -eq 1 ]] && echo yes || echo no)
  Subnet router:  $([[ "${SUBNET}" -eq 1 ]] && echo "yes: ${ROUTES//,/, }" || echo no)
  Tailscale SSH:  $([[ "${TS_SSH}" -eq 1 ]] && echo on || echo off)
  DNS:            $([[ "${TS_DNS}" -eq 1 ]] && echo "tailnet DNS" || echo "this machine's own (tailnet DNS off)")
  Sign-in:        ${signInLine}"

  if [[ "${EXIT_NODE}" -eq 1 || "${SUBNET}" -eq 1 ]]; then
    routing="

For routing it also turns on IP forwarding (${SYSCTL_FILE}) and \
Tailscale's recommended UDP setting on $(lanInterface || echo "the LAN interface"). \
New routes and exit nodes must then be approved once in the admin console."
  fi

  ask --yes-button "Apply" --no-button "Cancel" "Set up Tailscale" \
    "${text}${routing}"
}

### Apply

installTailscale() {
  local target dist codename tmpdir

  target="$(repoTarget)" || die "No Tailscale packages for this system"
  read -r dist codename <<< "${target}"
  tmpdir="$(mktemp -d)" || die "Could not create a temporary folder"

  log "Adding Tailscale's package repository (${dist} ${codename})..."

  if ! curl -fsSL --max-time 30 -o "${tmpdir}/keyring.gpg" \
    "${TS_PKGS_URL}/${dist}/${codename}.noarmor.gpg" \
    || ! curl -fsSL --max-time 30 -o "${tmpdir}/tailscale.list" \
      "${TS_PKGS_URL}/${dist}/${codename}.tailscale-keyring.list"; then
    rm -rf "${tmpdir}"
    die "Could not download Tailscale's repository files for ${dist} \
${codename} from ${TS_PKGS_URL}."
  fi

  if [[ ! -s "${tmpdir}/keyring.gpg" ]] \
    || ! grep -q '^deb .*tailscale' "${tmpdir}/tailscale.list"; then
    rm -rf "${tmpdir}"
    die "Tailscale's repository files for ${dist} ${codename} look wrong."
  fi

  if ! install -m 644 "${tmpdir}/keyring.gpg" "${TS_KEYRING}" \
    || ! install -m 644 "${tmpdir}/tailscale.list" "${TS_SOURCES}"; then
    die "Could not add Tailscale's repository"
  fi

  rm -rf "${tmpdir}"

  log "Installing Tailscale..."
  apt-get -q -o DPkg::Lock::Timeout=300 update \
    || die "apt-get update failed (see the output above)"
  DEBIAN_FRONTEND=noninteractive apt-get -q -o DPkg::Lock::Timeout=300 \
    install -y tailscale || die "Could not install Tailscale"
}

enableForwarding() {
  log "Turning on IP forwarding (${SYSCTL_FILE})..."
  printf '%s\n' \
    "# Written by the PiVPN Tailscale setup: Tailscale exit node / subnet router" \
    "net.ipv4.ip_forward = 1" \
    "net.ipv6.conf.all.forwarding = 1" > "${SYSCTL_FILE}"
  sysctl -q -p "${SYSCTL_FILE}" || warn "could not apply ${SYSCTL_FILE}"
}

# Tailscale's recommendation for exit nodes and subnet routers on Linux 6.2+
# (https://tailscale.com/kb/1320/performance-best-practices)
tuneUdpGro() {
  local dev unitFile="/etc/systemd/system/tailscale-udp-gro.service"
  local dispatcher="/etc/networkd-dispatcher/routable.d/50-tailscale"

  dev="$(lanInterface)"
  [[ -n "${dev}" ]] || return 0
  installPackages ethtool

  if ! ethtool -k "${dev}" 2> /dev/null \
    | grep -qE '^rx-udp-gro-forwarding: (on|off)$'; then
    log "UDP GRO forwarding can't be changed on ${dev}; skipping it."
    return 0
  fi

  log "Turning on UDP GRO forwarding on ${dev}..."
  ethtool -K "${dev}" rx-udp-gro-forwarding on rx-gro-list off 2> /dev/null \
    || warn "ethtool could not change ${dev}"

  # Again on every boot: through networkd-dispatcher where systemd-networkd
  # manages the network (Ubuntu Server), otherwise with a small unit
  if systemctl is-active --quiet systemd-networkd; then
    installPackages networkd-dispatcher
    mkdir -p "${dispatcher%/*}"
    printf '#!/bin/sh\n\nethtool -K %s rx-udp-gro-forwarding on rx-gro-list off\n' \
      "${dev}" > "${dispatcher}"
    chmod 755 "${dispatcher}"
    systemctl enable --now networkd-dispatcher > /dev/null 2>&1 \
      || warn "could not enable networkd-dispatcher"
  else
    printf '%s\n' \
      "[Unit]" \
      "Description=UDP GRO forwarding on ${dev} for Tailscale" \
      "After=network-online.target" \
      "Wants=network-online.target" \
      "" \
      "[Service]" \
      "Type=oneshot" \
      "ExecStart=$(command -v ethtool) -K ${dev} rx-udp-gro-forwarding on rx-gro-list off" \
      "" \
      "[Install]" \
      "WantedBy=multi-user.target" > "${unitFile}"
    systemctl daemon-reload
    systemctl enable tailscale-udp-gro.service > /dev/null 2>&1 \
      || warn "could not enable tailscale-udp-gro.service"
  fi
}

# The settings as flags for 'tailscale up' and 'tailscale set'
prefFlags() {
  local routes=""

  [[ "${SUBNET}" -eq 1 ]] && routes="${ROUTES}"
  printf '%s\n' \
    "--advertise-exit-node=$(yesNo "${EXIT_NODE}")" \
    "--advertise-routes=${routes}" \
    "--accept-dns=$(yesNo "${TS_DNS}")" \
    "--ssh=$(yesNo "${TS_SSH}")"
}

# Sign in (and apply the settings) with 'tailscale up'; true on success.
# On failure LOGIN_ERROR has the end of its output.
signIn() {
  local flags keyFile="" logFile rc

  mapfile -t flags < <(prefFlags)
  LOGIN_ERROR=""
  logFile="$(mktemp)" || die "Could not create a temporary file"
  clear 2> /dev/null || printf '\033[H\033[2J'

  if [[ "${AUTH}" == "key" ]]; then
    keyFile="$(mktemp)" || die "Could not create a temporary file"
    chmod 600 "${keyFile}"
    printf '%s' "${AUTH_KEY}" > "${keyFile}"
    log "Signing in to Tailscale with the auth key..."
    flags+=(--timeout=2m "--auth-key=file:${keyFile}")
  else
    log "Sign in to Tailscale: open the link below on any device (or scan the"
    log "QR code), sign in to your Tailscale account and connect this machine."
    log "The setup goes on by itself afterwards (Ctrl+C cancels)."
    flags+=(--qr --timeout=15m)
  fi

  # Ctrl+C stops 'tailscale up', not this setup
  INTERRUPTED=0
  trap 'INTERRUPTED=1; echo' INT
  tailscale up --reset --accept-risk=lose-ssh "${flags[@]}" 2>&1 \
    | tee "${logFile}"
  rc="${PIPESTATUS[0]}"
  trap - INT

  [[ -n "${keyFile}" ]] && rm -f "${keyFile}"
  LOGIN_ERROR="$(grep -v -e '^[[:space:]]*$' -e '[█▀▄]' -e 'To authenticate' \
    -e 'login.tailscale.com/a/' "${logFile}" | tail -n 4 | cut -c 1-200)"
  rm -f "${logFile}"

  if [[ "${INTERRUPTED}" -eq 1 ]]; then
    LOGIN_ERROR="Cancelled with Ctrl+C."
    rc=1
  elif [[ "${rc}" -ne 0 ]]; then
    LOGIN_ERROR="${LOGIN_ERROR:-tailscale up stopped with exit status ${rc}.}"
  fi

  return "${rc}"
}

applySettings() {
  local flags choice i

  if [[ "${INSTALLED}" -eq 0 ]]; then
    installTailscale
  fi

  systemctl enable --now tailscaled > /dev/null 2>&1 \
    || die "Could not start tailscaled"

  # tailscaled needs a moment after a (re)start before it answers
  for ((i = 0; i < 20; i++)); do
    tsStatus > /dev/null && break
    sleep 0.5
  done

  readState

  if [[ "${EXIT_NODE}" -eq 1 || "${SUBNET}" -eq 1 ]]; then
    enableForwarding
    tuneUdpGro
  fi

  if [[ "${SIGNED_IN}" -eq 1 ]]; then
    mapfile -t flags < <(prefFlags)
    log "Applying the settings..."
    tailscale set --accept-risk=lose-ssh "${flags[@]}" \
      || die "tailscale set failed (see the output above)"

    if [[ "${STATE}" == "Stopped" ]]; then
      log "Bringing Tailscale up..."
      tailscale up --timeout=1m || warn "tailscale up failed"
    fi
  else
    while ! signIn; do
      local options=("Retry" "Try signing in again")
      [[ "${AUTH}" == "key" ]] \
        && options+=("Link" "Sign in with a link or QR code instead")

      if ! choose choice --cancel "Stop" "Tailscale sign-in" "The sign-in \
did not complete:

${LOGIN_ERROR}

Tailscale is installed and set up, but this machine is not signed in yet." \
        "${options[@]}"; then
        msg "Tailscale not signed in" "Tailscale is installed but not \
signed in. Run this setup again to sign in, or: sudo tailscale up"
        exit "${EXIT_CANCELLED}"
      fi

      [[ "${choice}" == "Link" ]] && AUTH="link"
    done
  fi

  # Let the new settings reach the coordination server
  for ((i = 0; i < 20; i++)); do
    [[ "$(tsStatus | jq -r '.BackendState // empty')" == "Running" ]] && break
    sleep 0.5
  done

  finish
}

finish() {
  local json name ip state exitOk primary expiry route text approve=0

  json="$(tsStatus)"
  name="$(jq -r '.Self.HostName // empty' <<< "${json}")"
  ip="$(jq -r '(.Self.TailscaleIPs // [])[0] // empty' <<< "${json}")"
  state="$(jq -r '.BackendState // empty' <<< "${json}")"
  TAILNET="$(jq -r '.CurrentTailnet.Name // empty' <<< "${json}")"
  exitOk="$(jq -r '.Self.ExitNodeOption // false' <<< "${json}")"
  primary="$(jq -r '(.Self.PrimaryRoutes // [])[]' <<< "${json}")"
  expiry="$(jq -r '.Self.KeyExpiry // empty' <<< "${json}")"

  case "${state}" in
    Running) text="Tailscale is running." ;;
    NeedsMachineAuth)
      text="Tailscale is signed in, but your tailnet requires device \
approval: approve this machine at ${ADMIN_URL}."
      ;;
    Stopped) text="Tailscale is signed in but stopped (sudo tailscale up starts it)." ;;
    *) text="Tailscale is set up (state: ${state:-unknown})." ;;
  esac

  text+="

  Machine:        ${name:-$(hostname -s)}${ip:+ (${ip})}${TAILNET:+ in ${TAILNET}}"

  if [[ "${EXIT_NODE}" -eq 1 ]]; then
    if [[ "${exitOk}" == "true" ]]; then
      text+="
  Exit node:      offered and approved"
    else
      text+="
  Exit node:      offered, waiting for approval"
      approve=1
    fi
  fi

  if [[ "${SUBNET}" -eq 1 ]]; then
    for route in ${ROUTES//,/ }; do
      if grep -qxF "${route}" <<< "${primary}"; then
        text+="
  Subnet route:   ${route}, active through this machine"
      else
        text+="
  Subnet route:   ${route}, waiting for approval"
        approve=1
      fi
    done
  fi

  text+="
  SSH / DNS:      $([[ "${TS_SSH}" -eq 1 ]] && echo "Tailscale SSH on" || echo "Tailscale SSH off") / \
$([[ "${TS_DNS}" -eq 1 ]] && echo "tailnet DNS" || echo "own DNS")"

  if [[ "${approve}" -eq 1 || -n "${expiry}" ]]; then
    text+="

Next, at ${ADMIN_URL}
open the ... menu of ${name:-this machine} and choose:"
    [[ "${approve}" -eq 1 ]] && text+="
  - Edit route settings: tick the routes and Use as exit node"
    [[ -n "${expiry}" ]] && text+="
  - Disable key expiry (else it drops off on ${expiry%%T*})"
  fi

  if [[ "${SUBNET}" -eq 1 ]]; then
    text+="

Linux devices use the subnet routes after running:
  sudo tailscale set --accept-routes"
  fi

  msg "Tailscale is set up" "${text}"
}

main() {
  needTerminal
  elevate "$@"
  needWhiptail
  needSystemd

  installPackages curl ca-certificates jq
  readState
  loadPrefs

  wizard stepIntro stepRoles stepRoutes stepAuth stepConfirm

  applySettings
}

main "$@"
