# shellcheck shell=bash
# extras/lib/common.sh: helpers shared by the PiVPN setup menu
# (extras/setup.sh) and the guided setups of the extras
# (extras/*/setup.sh). Sourced, not run.
#
# Dialogs use whiptail with the same sizing rules as the PiVPN installer, so
# the extras look and behave like PiVPN itself.

# Exit status of a setup the user stopped (the menu doesn't pause for it)
EXIT_CANCELLED=2

# Title shown at the top left of every dialog; each script sets its own
BACKTITLE="${BACKTITLE:-PiVPN Setup}"

# Shown by confirmStop(); a setup updates it once it has changed something
STOP_NOTE="Nothing on this machine has been changed yet."

# English output from the tools we parse, but keep UTF-8 for names
if locale -a 2> /dev/null | grep -qix 'c\.utf-\?8'; then
  export LC_ALL=C.UTF-8
else
  export LC_ALL=C
fi

### Messages

log() {
  echo "::: $*"
}

warn() {
  echo "::: WARNING: $*" >&2
}

# die <message>: report an error (in a dialog when there is a terminal) and
# exit 1
die() {
  echo "::: ERROR: $*" >&2

  if [[ -t 0 && -t 1 ]] && command -v whiptail > /dev/null; then
    tuiSize
    whiptail --backtitle "${BACKTITLE}" --title "Error" \
      --msgbox "$*" "$(boxHeight "$*" 8)" "${c}"
  fi

  exit 1
}

### Checks

# want <command>: true when the command is available
want() {
  command -v "$1" > /dev/null 2>&1
}

# need <command>...: die unless every command is available
need() {
  local cmd

  for cmd in "$@"; do
    want "${cmd}" || die "'${cmd}' is required but not installed"
  done
}

root() {
  [[ "${EUID}" -eq 0 ]]
}

# elevate "$@": re-run the calling script as root with sudo, if needed.
# The script sets SCRIPT_PATH before sourcing this file.
elevate() {
  root && return 0

  want sudo || die "Please run this as root (sudo is not installed)."
  log "sudo will be used for the setup."
  exec sudo bash "${SCRIPT_PATH}" "$@"
}

needTerminal() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "::: ERROR: this setup asks questions, run it in a terminal" >&2
    exit 1
  fi

  if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
    export TERM=xterm
  fi
}

needSystemd() {
  [[ -d /run/systemd/system ]] \
    || die "This machine is not running systemd, which the setup needs for its services."
}

# Install whiptail if it is missing (it is on Ubuntu and Debian by default)
needWhiptail() {
  want whiptail && return 0

  log "Installing whiptail for the setup dialogs..."

  if root; then
    installPackages whiptail
  else
    sudo apt-get install -y whiptail
  fi

  want whiptail || die "Could not install whiptail"
}

### Dialogs

# Half the screen, at least 20x70, like the PiVPN installer (but never larger
# than the screen). Sets r, c, the screen size in rows, cols, and the largest
# usable dialog height in maxh.
tuiSize() {
  local size

  # From the terminal itself: stdin may be a pipe here
  size="$(stty size < /dev/tty 2> /dev/null || echo 24 80)"
  rows="${size% *}"
  cols="${size#* }"
  [[ "${rows}" =~ ^[0-9]+$ ]] || rows=24
  [[ "${cols}" =~ ^[0-9]+$ ]] || cols=80

  r=$((rows / 2))
  c=$((cols / 2))
  r=$((r < 20 ? 20 : r))
  c=$((c < 70 ? 70 : c))
  # Leave the title line (and one more) free
  maxh=$((rows > 12 ? rows - 2 : rows))
  r=$((r > maxh ? maxh : r))
  c=$((c > cols ? cols : c))
}

# textLines <text>: how many lines <text> takes in a dialog (an estimate)
textLines() {
  printf '%s\n' "$1" | fold -s -w "$((c - 4))" | wc -l
}

# boxHeight <text> <extra lines>: a height that fits <text> plus <extra>
# lines of frame and buttons; at least r, at most the screen (less the title)
boxHeight() {
  local height

  height=$(($(textLines "$1") + $2))
  height=$((height < r ? r : height))
  height=$((height > maxh ? maxh : height))
  echo "${height}"
}

# boxOverflows <text> <extra lines>: true when even the largest dialog is too
# small for <text>, which then needs to scroll
boxOverflows() {
  [[ $(($(textLines "$1") + $2)) -gt "${maxh}" ]]
}

# msg <title> <text>
msg() {
  local scroll=()

  tuiSize
  boxOverflows "$2" 7 && scroll=(--scrolltext)
  whiptail --backtitle "${BACKTITLE}" --title "$1" "${scroll[@]}" \
    --msgbox "$2" "$(boxHeight "$2" 7)" "${c}"
}

# ask [--no] [--yes-button <label>] [--no-button <label>] <title> <text>
# Returns 0 for yes, 1 for no and 255 for Esc.
ask() {
  local opts=()

  while [[ "$1" == --* ]]; do
    case "$1" in
      --no)
        opts+=(--defaultno)
        shift
        ;;
      --yes-button | --no-button)
        opts+=("$1" "$2")
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  tuiSize
  # On a small screen, let a long text scroll (Tab reaches the buttons)
  boxOverflows "$2" 7 && opts+=(--scrolltext)
  whiptail --backtitle "${BACKTITLE}" --title "$1" "${opts[@]}" \
    --yesno "$2" "$(boxHeight "$2" 7)" "${c}"
}

# input <var> <title> <text> [default]: returns 1 on Cancel or Esc
input() {
  local __out

  tuiSize
  __out="$(whiptail --backtitle "${BACKTITLE}" --title "$2" \
    --inputbox "$3" "$(boxHeight "$3" 9)" "${c}" "${4:-}" \
    3>&1 1>&2 2>&3)" || return 1
  printf -v "$1" '%s' "${__out}"
}

# secret <var> <title> <text>: like input, but the typing is hidden
secret() {
  local __out

  tuiSize
  __out="$(whiptail --backtitle "${BACKTITLE}" --title "$2" \
    --passwordbox "$3" "$(boxHeight "$3" 9)" "${c}" \
    3>&1 1>&2 2>&3)" || return 1
  printf -v "$1" '%s' "${__out}"
}

# listHeight <text> <box height> <items>: rows for the list of a menu, so
# that the text, the list and the buttons all fit (the list scrolls)
listHeight() {
  local room=$(($2 - $(textLines "$1") - 7))

  room=$((room < 1 ? 1 : room))
  echo "$(($3 < room ? $3 : room))"
}

# choose <var> [--default <tag>] [--notags] [--cancel <label>] <title> <text>
#        <tag> <item>...
# A menu; returns 1 on Cancel or Esc.
choose() {
  local __var="$1" __opts=() __out __items __height
  shift

  while [[ "$1" == --* ]]; do
    case "$1" in
      --default)
        [[ -n "$2" ]] && __opts+=(--default-item "$2")
        shift 2
        ;;
      --notags)
        __opts+=(--notags)
        shift
        ;;
      --cancel)
        __opts+=(--cancel-button "$2")
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  local __title="$1" __text="$2"
  shift 2
  __items=$(($# / 2))

  tuiSize
  __height="$(boxHeight "${__text}" $((__items + 8)))"
  __out="$(whiptail --backtitle "${BACKTITLE}" --title "${__title}" "${__opts[@]}" \
    --menu "${__text}" "${__height}" "${c}" \
    "$(listHeight "${__text}" "${__height}" "${__items}")" "$@" \
    3>&1 1>&2 2>&3)" || return 1
  printf -v "${__var}" '%s' "${__out}"
}

# checklist <var> <title> <text> <tag> <item> <ON|OFF>...
# Sets <var> to the chosen tags, one per line; returns 1 on Cancel or Esc.
checklist() {
  local __var="$1" __title="$2" __text="$3" __out __items __height
  shift 3
  __items=$(($# / 3))

  tuiSize
  __height="$(boxHeight "${__text}" $((__items + 8)))"
  __out="$(whiptail --backtitle "${BACKTITLE}" --title "${__title}" \
    --separate-output --checklist "${__text}" "${__height}" "${c}" \
    "$(listHeight "${__text}" "${__height}" "${__items}")" "$@" \
    3>&1 1>&2 2>&3)" || return 1
  printf -v "${__var}" '%s' "${__out}"
}

# radiolist <var> <title> <text> <tag> <item> <ON|OFF>...
radiolist() {
  local __var="$1" __title="$2" __text="$3" __out __items __height
  shift 3
  __items=$(($# / 3))

  tuiSize
  __height="$(boxHeight "${__text}" $((__items + 8)))"
  __out="$(whiptail --backtitle "${BACKTITLE}" --title "${__title}" \
    --radiolist "${__text}" "${__height}" "${c}" \
    "$(listHeight "${__text}" "${__height}" "${__items}")" "$@" \
    3>&1 1>&2 2>&3)" || return 1
  [[ -n "${__out}" ]] || return 1
  printf -v "${__var}" '%s' "${__out}"
}

# confirmStop: asks whether to stop the setup; true means stop
confirmStop() {
  ask --no --yes-button "Stop" --no-button "Go back" "Stop the setup?" \
    "Stop the ${SETUP_NAME:-setup} now?

${STOP_NOTE}"
}

# wizard <step function>...
# Runs the steps in order. A step returns 0 to go on, 1 when the user
# cancelled (on the first step that ends the setup; later, the user is asked
# whether to stop, and "Go back" repeats the step), or 2 after setting
# WIZARD_GOTO to an earlier step to return to.
wizard() {
  local steps=("$@") i=0 rc j

  while [[ "${i}" -lt "${#steps[@]}" ]]; do
    WIZARD_GOTO=""
    "${steps[i]}"
    rc=$?

    case "${rc}" in
      0)
        i=$((i + 1))
        ;;
      2)
        for j in "${!steps[@]}"; do
          [[ "${steps[j]}" == "${WIZARD_GOTO}" ]] && i="${j}"
        done
        ;;
      *)
        if [[ "${i}" -eq 0 ]] || confirmStop; then
          log "${SETUP_NAME:-Setup} stopped, nothing more was changed."
          exit "${EXIT_CANCELLED}"
        fi
        ;;
    esac
  done
}

### Packages and users

# installPackages <package>...: apt-get install whatever is missing
installPackages() {
  local pkg missing=()

  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "${pkg}" 2> /dev/null \
      | grep -q "ok installed" || missing+=("${pkg}")
  done

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  log "Installing ${missing[*]}..."

  # Wait for unattended-upgrades instead of failing on the dpkg lock, and
  # refresh the package lists once if the first try fails (new machine)
  if ! aptInstall "${missing[@]}"; then
    log "Refreshing the package lists and trying again..."

    if ! apt-get -q -o DPkg::Lock::Timeout=300 update \
      || ! aptInstall "${missing[@]}"; then
      die "Could not install ${missing[*]} (see the output above)"
    fi
  fi
}

aptInstall() {
  DEBIAN_FRONTEND=noninteractive apt-get -q -o DPkg::Lock::Timeout=300 \
    install -y --no-install-recommends "$@"
}

# userHome <user>
userHome() {
  getent passwd "$1" | cut -d ':' -f 6
}

# runAs <user> [VAR=value...] <command>...: run a command as <user> with a
# clean environment, from that user's home folder
runAs() {
  local user="$1" home
  shift
  home="$(userHome "${user}")"

  (
    cd "${home:-/}" 2> /dev/null || cd /
    runuser -u "${user}" -- env -i \
      HOME="${home}" USER="${user}" LOGNAME="${user}" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG="${LC_ALL}" TERM="${TERM:-dumb}" \
      "$@"
  )
}

# Normal login users (UID 1000-60000 with a login shell), one per line
loginUsers() {
  awk -F ':' '$3 >= 1000 && $3 <= 60000 && $7 !~ /(nologin|false)$/ {print $1}' \
    /etc/passwd
}

# pivpnSetting <name>: a value from PiVPN's setupVars.conf (WireGuard's
# first, then OpenVPN's); fails when PiVPN isn't installed or lacks it
pivpnSetting() {
  local file value

  for file in /etc/pivpn/wireguard/setupVars.conf \
    /etc/pivpn/openvpn/setupVars.conf; do
    [[ -r "${file}" ]] || continue
    value="$(sed -n "s/^$1=//p" "${file}" | tail -n 1)"
    value="${value#[\"\']}"
    value="${value%[\"\']}"

    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done

  return 1
}

# Installed PiVPN protocols: "WireGuard", "OpenVPN", "WireGuard + OpenVPN"
# or nothing
pivpnProtocols() {
  local found=()

  [[ -r /etc/pivpn/wireguard/setupVars.conf ]] && found+=("WireGuard")
  [[ -r /etc/pivpn/openvpn/setupVars.conf ]] && found+=("OpenVPN")

  if [[ "${#found[@]}" -eq 2 ]]; then
    echo "WireGuard + OpenVPN"
  elif [[ "${#found[@]}" -eq 1 ]]; then
    echo "${found[0]}"
  fi
}

# chooseUser <var> <title> <text>: the PiVPN install user if PiVPN is
# installed, otherwise ask (the user who ran sudo preselected)
chooseUser() {
  local __var="$1" __title="$2" __text="$3" __user __list=() __name __state

  if __user="$(pivpnSetting install_user)" && id "${__user}" > /dev/null 2>&1; then
    printf -v "${__var}" '%s' "${__user}"
    return 0
  fi

  while IFS= read -r __name; do
    [[ -z "${__name}" ]] && continue
    __state="OFF"
    [[ "${__name}" == "${SUDO_USER:-}" ]] && __state="ON"
    __list+=("${__name}" "" "${__state}")
  done < <(loginUsers)

  case "$((${#__list[@]} / 3))" in
    0)
      die "There is no normal user account on this machine. Create one first (or install PiVPN, which offers to)."
      ;;
    1)
      printf -v "${__var}" '%s' "${__list[0]}"
      return 0
      ;;
  esac

  # Preselect the first user when the one who ran sudo isn't listed
  if [[ " ${__list[*]} " != *" ON "* ]]; then
    __list[2]="ON"
  fi

  radiolist "${__var}" "${__title}" "${__text}" "${__list[@]}"
}

### Networking

# The interface of the default IPv4 route (PiVPN's choice if it has one)
lanInterface() {
  local dev

  if dev="$(pivpnSetting IPv4dev)" && [[ -e "/sys/class/net/${dev}" ]]; then
    echo "${dev}"
    return 0
  fi

  ip -4 route show default 2> /dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

# ipToInt <a.b.c.d>, intToIp <number>
ipToInt() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

intToIp() {
  echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

# validCidr4 <a.b.c.d/n>
validCidr4() {
  local ip="${1%/*}" bits="${1#*/}" part

  [[ "$1" == */* && "${bits}" =~ ^[0-9]+$ && "${bits}" -le 32 ]] || return 1
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

  for part in ${ip//./ }; do
    [[ "${part}" =~ ^0[0-9] ]] && return 1
    [[ "${part}" -le 255 ]] || return 1
  done
}

# networkOf <a.b.c.d/n>: the network address, e.g. 192.168.11.0/24
networkOf() {
  local ip="${1%/*}" bits="${1#*/}" mask

  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  echo "$(intToIp $(($(ipToInt "${ip}") & mask)))/${bits}"
}

# lanCidr: the LAN this machine is on, e.g. 192.168.11.0/24
lanCidr() {
  local dev addr

  dev="$(lanInterface)"
  [[ -n "${dev}" ]] || return 1
  addr="$(ip -4 -o addr show dev "${dev}" scope global 2> /dev/null \
    | awk '{print $4; exit}')"
  validCidr4 "${addr}" || return 1
  networkOf "${addr}"
}

# The machine's LAN address (without prefix length)
lanAddress() {
  local dev

  dev="$(lanInterface)"
  [[ -n "${dev}" ]] || return 1
  ip -4 -o addr show dev "${dev}" scope global 2> /dev/null \
    | awk '{sub(/\/.*/, "", $4); print $4; exit}'
}

### Files

# systemdQuote <value>: a value for a systemd EnvironmentFile, in double
# quotes with backslashes and quotes escaped
systemdQuote() {
  local value="${1//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

# setEnvVar <file> <name> <value>: set NAME=value in an EnvironmentFile,
# replacing an existing or commented-out (#NAME=) line, or appending one.
# An empty value comments the setting out.
setEnvVar() {
  local file="$1" name="$2" value="$3" line tmp

  if [[ -n "${value}" ]]; then
    line="${name}=${value}"
  else
    line=""
  fi

  tmp="$(mktemp)" || die "Could not create a temporary file"
  # Through the environment: awk -v would interpret the backslashes
  SET_NAME="${name}" SET_LINE="${line}" awk '
    BEGIN { done = 0; name = ENVIRON["SET_NAME"]; line = ENVIRON["SET_LINE"] }
    $0 ~ "^#?[[:space:]]*" name "=" {
      if (!done) {
        if (line != "") { print line } else { sub(/^#?[[:space:]]*/, "#"); print }
        done = 1
      } else if ($0 !~ /^#/) {
        next
      } else {
        print
      }
      next
    }
    { print }
    END { if (!done && line != "") print line }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    die "Could not update ${file}"
  }

  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

# getEnvVar <file> <name>: a value from an EnvironmentFile, unquoted
getEnvVar() {
  local value

  [[ -r "$1" ]] || return 1
  value="$(sed -n "s/^$2=//p" "$1" | tail -n 1)"
  [[ -n "${value}" ]] || return 1

  if [[ "${value}" == \"*\" ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\"/\"}"
    value="${value//\\\\/\\}"
  elif [[ "${value}" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s\n' "${value}"
}

# Last 4 characters of a secret, for "keep the current token (...abcd)"
tail4() {
  printf '...%s' "${1: -4}"
}
