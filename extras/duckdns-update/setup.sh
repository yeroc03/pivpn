#!/bin/bash
# Guided setup of the DuckDNS updater (extras/duckdns-update).
#
# Asks for your DuckDNS subdomain(s) and token (and, optionally, a Gotify
# server for alerts), checks them with DuckDNS, then installs and starts
# duckdns-update and its 5-minute systemd timer. Run it again to change the
# settings; the current ones are filled in.
#
#   extras/duckdns-update/setup.sh     (or: ./install.sh in the clone, then DuckDNS)
#
# Runs itself with sudo when started as a normal user.

# shellcheck source-path=SCRIPTDIR
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

set -o nounset

BACKTITLE="PiVPN Setup - DuckDNS"
SETUP_NAME="DuckDNS setup"

CONF_FILE="/etc/duckdns-update.conf"
STATE_FILE="/var/lib/duckdns-update/state"
DUCKDNS_URL="${DUCKDNS_URL:-https://www.duckdns.org/update}"

# Settings (current ones loaded from CONF_FILE)
DOMAINS=""
TOKEN=""
GOTIFY_URL=""
GOTIFY_TOKEN=""
GOTIFY_ON=0
CURRENT_TOKEN=""

# Results of the checks along the way
CHECKED_IP=""
CHECK_STATE=""  # ok, skipped
GOTIFY_STATE="" # sent, skipped, failed
DISABLE_UNITS=()

### Helpers

# The DuckDNS name in PiVPN's client profiles, if it is one: myhome for
# myhome.duckdns.org (or vpn.myhome.duckdns.org)
pivpnDuckName() {
  local host

  host="$(pivpnSetting pivpnHOST)" || return 1
  host="${host,,}"
  [[ "${host}" == *.duckdns.org ]] || return 1
  host="${host%.duckdns.org}"
  echo "${host##*.}"
}

# fullNames <a,b>: "a.duckdns.org, b.duckdns.org"
fullNames() {
  local names="$1"
  names="${names//,/.duckdns.org, }"
  echo "${names}.duckdns.org"
}

# gotifySend <url> <token> <title> <message> <priority>: prints curl's error
# on failure. The token goes to curl on stdin, never on its command line.
gotifySend() {
  printf 'header = "X-Gotify-Key: %s"\n' "$2" \
    | curl -fsS --max-time 15 -o /dev/null -K - \
      --form-string "title=$3" --form-string "message=$4" \
      --form-string "priority=$5" "${1%/}/message" 2>&1
}

# curlReason <curl error output>: the error in plain words
curlReason() {
  case "$1" in
    *"(6)"*) echo "the server name could not be resolved" ;;
    *"(7)"*) echo "the connection was refused (wrong address or port?)" ;;
    *"(28)"*) echo "the server did not answer in time" ;;
    *"(35)"* | *"(60)"* | *"(77)"*)
      echo "its TLS certificate is not trusted by this machine"
      ;;
    *"error: 401"* | *"error: 403"*) echo "the token was refused" ;;
    *"error: 404"*) echo "nothing answered at that address (404)" ;;
    *) echo "${1:-unknown error}" ;;
  esac
}

loadCurrent() {
  local value

  [[ -r "${CONF_FILE}" ]] || return 0

  value="$(getEnvVar "${CONF_FILE}" DUCKDNS_DOMAINS)" && DOMAINS="${value}"
  value="$(getEnvVar "${CONF_FILE}" DUCKDNS_TOKEN)" && TOKEN="${value}"
  value="$(getEnvVar "${CONF_FILE}" GOTIFY_URL)" && GOTIFY_URL="${value}"
  value="$(getEnvVar "${CONF_FILE}" GOTIFY_TOKEN)" && GOTIFY_TOKEN="${value}"

  # The example values from the template don't count
  [[ "${DOMAINS}" == "yourname" ]] && DOMAINS=""
  [[ "${TOKEN}" == "00000000-0000-0000-0000-000000000000" ]] && TOKEN=""
  CURRENT_TOKEN="${TOKEN}"

  if [[ -n "${GOTIFY_URL}" && -n "${GOTIFY_TOKEN}" ]]; then
    GOTIFY_ON=1
  fi
}

### Steps

stepIntro() {
  local text

  text="DuckDNS gives your home a name, such as myhome.duckdns.org, that \
your VPN clients use to find it. This sets up a timer that keeps the name \
pointing at your home's public IP address, checking every 5 minutes.

You need:
  - a DuckDNS account and subdomain (https://www.duckdns.org)
  - your DuckDNS token (at the top of that page, once signed in)

Optional: a Gotify server, for alerts when your home IP changes or updates \
stop working."

  if [[ -n "${DOMAINS}" ]]; then
    text+="

DuckDNS is already set up here for $(fullNames "${DOMAINS}"). Continue to \
change its settings; the current ones are filled in."
  fi

  ask --yes-button "Continue" --no-button "Cancel" "DuckDNS" "${text}"
}

stepDomains() {
  local value default part parts clean=() bad=""

  default="${DOMAINS}"
  [[ -z "${default}" ]] && default="$(pivpnDuckName)"

  while true; do
    input value "DuckDNS name" "Your DuckDNS subdomain: the part before \
.duckdns.org. Separate several with commas.

Example: myhome   (for myhome.duckdns.org)" "${default}" || return 1

    value="${value,,}"
    value="${value//[[:space:]]/}"
    clean=()
    bad=""
    IFS=',' read -r -a parts <<< "${value}"

    for part in "${parts[@]}"; do
      part="${part#http://}"
      part="${part#https://}"
      part="${part%%/*}"
      part="${part%.}"
      part="${part%.duckdns.org}"
      [[ -z "${part}" ]] && continue

      if [[ "${part}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        [[ " ${clean[*]} " == *" ${part} "* ]] || clean+=("${part}")
      else
        bad="${part}"
      fi
    done

    if [[ -n "${bad}" ]]; then
      msg "DuckDNS name" "\"${bad}\" is not a DuckDNS subdomain.

Enter just the part before .duckdns.org (letters, digits and hyphens), \
for example myhome."
      default="${value}"
    elif [[ "${#clean[@]}" -eq 0 ]]; then
      msg "DuckDNS name" "Enter at least one DuckDNS subdomain."
      default=""
    else
      DOMAINS="$(
        IFS=,
        echo "${clean[*]}"
      )"
      return 0
    fi
  done
}

stepToken() {
  local value text

  text="Your DuckDNS token. Sign in at https://www.duckdns.org: the token is \
at the top of the page and looks like a1b2c3d4-e5f6-7890-abcd-ef1234567890.

Paste it with Shift+Insert, Ctrl+Shift+V or a right click, depending on \
your terminal. It stays hidden while you type."

  if [[ -n "${CURRENT_TOKEN}" ]]; then
    text+="

Leave it empty to keep the current token ($(tail4 "${CURRENT_TOKEN}"))."
  fi

  while true; do
    secret value "DuckDNS token" "${text}" || return 1
    value="${value//[[:space:]]/}"

    if [[ -z "${value}" ]]; then
      if [[ -n "${CURRENT_TOKEN}" ]]; then
        TOKEN="${CURRENT_TOKEN}"
        return 0
      fi

      msg "DuckDNS token" "The token is required."
      continue
    fi

    if [[ ! "${value}" =~ ^[A-Za-z0-9-]+$ ]]; then
      msg "DuckDNS token" "That isn't a DuckDNS token: tokens only contain \
letters, digits and hyphens. Try pasting it again."
      continue
    fi

    if [[ ! "${value,,}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      ask --no --yes-button "Use it" --no-button "Re-enter" "DuckDNS token" \
        "That doesn't look like a DuckDNS token, which has the form \
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (${#value} characters entered).

Use it anyway?" || continue
    fi

    TOKEN="${value}"
    return 0
  done
}

# Check the name(s) and token with DuckDNS. This is a real update, so the
# record points at this network afterwards.
stepCheck() {
  local response rc lines choice

  while true; do
    log "Checking $(fullNames "${DOMAINS}") with DuckDNS..."
    response="$(printf 'url = "%s?domains=%s&token=%s&ip=&verbose=true"\n' \
      "${DUCKDNS_URL}" "${DOMAINS}" "${TOKEN}" \
      | curl -4 -fsS --max-time 20 -K - 2>&1)"
    rc=$?
    mapfile -t lines <<< "${response}"

    if [[ "${rc}" -eq 0 && "${lines[0]:-}" == "OK" ]]; then
      CHECKED_IP="${lines[1]:-}"
      CHECK_STATE="ok"
      return 0
    fi

    if [[ "${rc}" -eq 0 && "${lines[0]:-}" == "KO" ]]; then
      choose choice --cancel "Cancel" "DuckDNS said no" \
        "DuckDNS refused the update. Either a name isn't one of your \
subdomains, or the token is wrong.

  Name:   $(fullNames "${DOMAINS}")
  Token:  $(tail4 "${TOKEN}")" \
        "Edit" "Change the name or the token" || return 1
      WIZARD_GOTO="stepDomains"
      return 2
    fi

    choose choice --cancel "Cancel" "DuckDNS not reachable" \
      "Could not reach DuckDNS to check the settings:

  $(curlReason "${lines[-1]:-}")

Check this machine's internet connection, or save the settings without \
checking (the timer keeps trying)." \
      "Retry" "Check again" \
      "Skip" "Save without checking" \
      "Edit" "Change the name or the token" || return 1

    case "${choice}" in
      Skip)
        CHECK_STATE="skipped"
        return 0
        ;;
      Edit)
        WIZARD_GOTO="stepDomains"
        return 2
        ;;
    esac
  done
}

stepGotify() {
  local value choice text defaultNo=(--no) error

  [[ "${GOTIFY_ON}" -eq 1 ]] && defaultNo=()

  ask "${defaultNo[@]}" "Gotify alerts" "Send alerts to your Gotify server \
when your home IP changes, when DuckDNS updates start failing, and when they \
work again?

You need the server's address and an application token (in Gotify: Apps, \
Create Application)."

  case $? in
    0) ;;
    1)
      GOTIFY_ON=0
      GOTIFY_STATE=""
      return 0
      ;;
    *) return 1 ;;
  esac

  # Server address
  value="${GOTIFY_URL:-https://}"

  while true; do
    input value "Gotify server" "The address of your Gotify server as this \
machine reaches it, for example https://gotify.example.lan or \
http://192.168.1.20:8080

With https, this machine must trust the server's certificate." \
      "${value}" || return 1
    value="${value//[[:space:]]/}"
    value="${value%/}"

    if [[ "${value}" =~ ^https?://[^/]+(/.*)?$ && "${value}" != *[\"\\]* ]]; then
      GOTIFY_URL="${value}"
      break
    fi

    msg "Gotify server" "Enter the full address, starting with https:// \
or http://"
  done

  # Application token
  text="The Gotify application token (in Gotify: Apps, then the eye icon \
next to the application). It stays hidden while you type."
  [[ -n "${GOTIFY_TOKEN}" ]] && text+="

Leave it empty to keep the current token ($(tail4 "${GOTIFY_TOKEN}"))."

  while true; do
    secret value "Gotify token" "${text}" || return 1
    value="${value//[[:space:]]/}"

    if [[ -z "${value}" && -n "${GOTIFY_TOKEN}" ]]; then
      break
    elif [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]]; then
      GOTIFY_TOKEN="${value}"
      break
    elif [[ -z "${value}" ]]; then
      msg "Gotify token" "The token is required for alerts."
    else
      msg "Gotify token" "Gotify tokens only contain letters, digits, dots, \
dashes and underscores. Try pasting it again."
    fi
  done

  GOTIFY_ON=1

  # Test message
  while true; do
    ask "Gotify alerts" "Send a test message to Gotify now?"

    case $? in
      0) ;;
      1)
        GOTIFY_STATE="skipped"
        return 0
        ;;
      *) return 1 ;;
    esac

    log "Sending a test message to ${GOTIFY_URL}..."

    if error="$(gotifySend "${GOTIFY_URL}" "${GOTIFY_TOKEN}" \
      "DuckDNS alerts for $(hostname -s)" \
      "Test from the PiVPN DuckDNS setup: alerts for $(fullNames "${DOMAINS}") will arrive here." 4)"; then
      GOTIFY_STATE="sent"
      msg "Gotify alerts" "Test message sent. Check that it arrived in \
your Gotify app."
      return 0
    fi

    choose choice --cancel "Cancel" "Gotify test failed" \
      "The test message could not be sent: $(curlReason "${error}").

  Server:  ${GOTIFY_URL}" \
      "Retry" "Send it again" \
      "Edit" "Change the server or the token" \
      "Keep" "Keep these settings anyway" \
      "Off" "No Gotify alerts" || return 1

    case "${choice}" in
      Edit)
        WIZARD_GOTO="stepGotify"
        return 2
        ;;
      Keep)
        GOTIFY_STATE="failed"
        return 0
        ;;
      Off)
        GOTIFY_ON=0
        GOTIFY_STATE=""
        return 0
        ;;
    esac
  done
}

# Other DuckDNS/dynamic DNS updaters that would update the same name
stepOtherUpdaters() {
  local unit

  DISABLE_UNITS=()

  for unit in inadyn ddclient; do
    systemctl is-active --quiet "${unit}" 2> /dev/null || continue

    ask "Other updater running" "${unit} is running on this machine. If it \
updates the same DuckDNS name, two updaters do the same job.

Stop and disable ${unit}? (Choose No if it updates other names.)"

    case $? in
      0) DISABLE_UNITS+=("${unit}") ;;
      1) ;;
      *) return 1 ;;
    esac
  done
}

stepConfirm() {
  local text ipLine gotifyLine duck

  case "${CHECK_STATE}" in
    ok) ipLine="points to ${CHECKED_IP} (checked just now)" ;;
    *) ipLine="not checked: the timer will keep trying" ;;
  esac

  if [[ "${GOTIFY_ON}" -eq 1 ]]; then
    gotifyLine="Gotify at ${GOTIFY_URL}"
    [[ "${GOTIFY_STATE}" == "sent" ]] && gotifyLine+=" (test sent)"
    [[ "${GOTIFY_STATE}" == "failed" ]] && gotifyLine+=" (test failed)"
  else
    gotifyLine="off"
  fi

  text="Ready to set up DuckDNS:

  Name:    $(fullNames "${DOMAINS}")
           ${ipLine}
  Token:   $(tail4 "${TOKEN}")
  Alerts:  ${gotifyLine}
  Checks:  every 5 minutes (systemd timer)

This installs:
  /usr/local/bin/duckdns-update
  /etc/systemd/system/duckdns-update.service and .timer
  ${CONF_FILE} (root only: it holds the tokens)"

  if [[ "${#DISABLE_UNITS[@]}" -gt 0 ]]; then
    text+="

It also stops and disables: ${DISABLE_UNITS[*]}"
  fi

  if duck="$(pivpnDuckName)" && [[ ",${DOMAINS}," != *",${duck},"* ]]; then
    text+="

Note: your PiVPN client profiles use $(pivpnSetting pivpnHOST), which is \
not one of these names."
  fi

  ask --yes-button "Install" --no-button "Cancel" "Set up DuckDNS" "${text}"
}

### Install

writeConfig() {
  local tmp

  tmp="$(mktemp)" || die "Could not create a temporary file"

  {
    echo "# ${CONF_FILE}  (root:root, mode 600: it holds the tokens)"
    echo "# Written by extras/duckdns-update/setup.sh; run it again to change it."
    echo
    echo "# Subdomain(s) without \".duckdns.org\", comma separated, no spaces"
    echo "DUCKDNS_DOMAINS=${DOMAINS}"
    echo "# From the top of https://www.duckdns.org after signing in"
    echo "DUCKDNS_TOKEN=${TOKEN}"
    echo
    echo "# Optional: Gotify alerts on IP change / failure / recovery."
    echo "# Use a URL this machine can reach and whose certificate it trusts."

    if [[ "${GOTIFY_ON}" -eq 1 ]]; then
      echo "GOTIFY_URL=$(systemdQuote "${GOTIFY_URL}")"
      echo "GOTIFY_TOKEN=${GOTIFY_TOKEN}"
    else
      echo "#GOTIFY_URL=https://gotify.example.lan"
      echo "#GOTIFY_TOKEN=AbCdEfGhIjKlMnO"
    fi
  } > "${tmp}"

  install -m 600 -o root -g root "${tmp}" "${CONF_FILE}" \
    || die "Could not write ${CONF_FILE}"
  rm -f "${tmp}"
}

applySettings() {
  local unit since rc state journal

  log "Installing the DuckDNS updater..."

  if ! install -m 755 "${SCRIPT_DIR}/duckdns-update" /usr/local/bin/duckdns-update \
    || ! install -m 644 "${SCRIPT_DIR}/duckdns-update.service" \
      "${SCRIPT_DIR}/duckdns-update.timer" /etc/systemd/system/; then
    die "Could not install the DuckDNS updater files"
  fi
  writeConfig

  for unit in "${DISABLE_UNITS[@]}"; do
    log "Stopping and disabling ${unit}..."
    systemctl disable --now "${unit}" || warn "could not disable ${unit}"
  done

  systemctl daemon-reload
  systemctl enable --now duckdns-update.timer \
    || die "Could not enable duckdns-update.timer"
  # Clear a failure left by an earlier run, so the menu's status is current
  systemctl reset-failed duckdns-update.service 2> /dev/null

  log "Running the first update..."
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl start duckdns-update.service
  rc=$?
  state="$(cat "${STATE_FILE}" 2> /dev/null)"
  journal="$(journalctl -u duckdns-update.service --since "${since}" \
    -o cat --no-pager 2> /dev/null | grep -v '^$' | tail -n 6)"

  if [[ "${rc}" -eq 0 && "${state}" == ok* ]]; then
    finish "${state#ok }"
  else
    msg "DuckDNS: first update failed" "DuckDNS is installed and the timer \
is running, but the first update failed:

${journal:-(no log output; see journalctl -u duckdns-update)}

The timer tries again every 5 minutes. To retry now:
  sudo systemctl start duckdns-update.service
  journalctl -u duckdns-update -n 20"
  fi
}

finish() {
  local ip="$1" text

  text="DuckDNS is set up.

  $(fullNames "${DOMAINS}")  ->  ${ip:-your public IP}

The record is checked every 5 minutes. A run that changes nothing logs \
nothing; an IP change or an error shows up in:
  journalctl -u duckdns-update"

  [[ "${GOTIFY_ON}" -eq 1 ]] && text+="

Gotify gets one message when your IP changes, one when updates start \
failing and one when they work again."

  text+="

On duckdns.org, leave the IPv6 field of the name empty: only the IPv4 \
address is kept current."

  msg "DuckDNS is set up" "${text}"
}

main() {
  needTerminal
  elevate "$@"
  needWhiptail
  needSystemd

  [[ -f "${SCRIPT_DIR}/duckdns-update" ]] \
    || die "duckdns-update is missing next to this script (${SCRIPT_DIR})"

  installPackages curl ca-certificates
  loadCurrent

  wizard stepIntro stepDomains stepToken stepCheck stepGotify \
    stepOtherUpdaters stepConfirm

  applySettings
}

main "$@"
