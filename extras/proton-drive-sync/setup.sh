#!/bin/bash
# Guided setup of the Proton Drive sync (extras/proton-drive-sync).
#
# Installs the official Proton Drive CLI if it is missing or outdated
# (downloaded from proton.me and checked against Proton's SHA-512), prepares
# an encrypted session store for the PiVPN user, signs that user in to Proton
# Drive (a link and QR code you approve on any device), asks which Proton
# Drive folder receives the profiles, then installs and starts the sync.
# Run it again to change the folder or sign in to another account.
#
#   extras/proton-drive-sync/setup.sh   (or: ./install.sh in the clone, then Proton Drive)
#
# Runs itself with sudo when started as a normal user.

# shellcheck source-path=SCRIPTDIR
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

set -o nounset

BACKTITLE="PiVPN Setup - Proton Drive"
SETUP_NAME="Proton Drive setup"

DEFAULTS_FILE="/etc/default/pivpn-proton-sync"
KEY_EMAIL="pivpn-proton-sync@localhost"

# The CLI's release list: per platform a download URL and its SHA-512
PD_MANIFEST_URL="${PD_MANIFEST_URL:-https://proton.me/download/drive/cli/version.json}"
PD_URL_PREFIX="https://proton.me/download/drive/cli/"
PD_INSTALL="/usr/local/bin/proton-drive"
# Used when the release list can't be read (from version.json, 2026-10-05)
PD_PIN_VERSION="0.9.0"
PD_PIN_SHA512_X64="3533025ba69ae112b64e3e01fbcc1ad0688136a4043f6cf6a72886967d85fdcd9ec235479c2e113171614be5225bfba93427509a05ca5aa6071d924fa7e91ca8"
PD_PIN_SHA512_ARM64="c8d5a6b174e57f06d05cb5483400b9963faf58e743b6b33706bb73ecff718047ffce6b439994255b94b5b226b90d2e91bef7418ec96c1c3f5d8bf39b6cd01321"

SYNC_USER=""
SYNC_HOME=""
PD="" # the CLI in use
PD_VERSION=""
PASS_ENV=() # PASSWORD_STORE_DIR=... when not using the default store
STORE_DIR=""
REMOTE=""
REMOTE_EXISTS=0
PRUNE=1

### Helpers

# pd <args>: the Proton Drive CLI, as the sync user, with the pass store
pd() {
  runAs "${SYNC_USER}" PROTON_DRIVE_CREDENTIALS_STORE=pass "${PASS_ENV[@]}" \
    "${PD}" "$@"
}

clearScreen() {
  clear 2> /dev/null || printf '\033[H\033[2J'
}

# versionGreater <a> <b>: true when version a > b
versionGreater() {
  [[ "$1" != "$2" ]] \
    && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# Proton's name for this machine's build: linux/x64, linux/arm64, ...
cliPlatform() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "linux/x64" ;;
    aarch64 | arm64) echo "linux/arm64" ;;
    *) return 1 ;;
  esac
}

hasAvx2() {
  grep -qw avx2 /proc/cpuinfo
}

cpuHelp() {
  echo "This machine's CPU lacks AVX2, which the standard Linux build of the \
Proton Drive CLI needs (it stops with \"Illegal instruction\").

On Proxmox, set the VM's CPU type to x86-64-v3 or host (Hardware, \
Processors, Type), restart the VM and run this setup again. Proxmox's \
default, x86-64-v2-AES, hides AVX2."
}

# latestRelease <platform>: "version<TAB>url<TAB>sha512" of the newest stable
# release for <platform>, from Proton's release list
latestRelease() {
  local json line version url sha

  json="$(curl -fsSL --max-time 20 "${PD_MANIFEST_URL}" 2> /dev/null)" \
    || return 1

  line="$(jq -r --arg p "$1" '
    [.Releases[]? | select((.CategoryName // "Stable") == "Stable")]
    | sort_by(.Version | split(".") | map(tonumber? // 0))
    | last // empty
    | . as $r
    | ($r.Files // $r.File // [])[]
    | select(.Platform == $p)
    | [$r.Version, .Url, .Sha512CheckSum]
    | @tsv' <<< "${json}" 2> /dev/null | head -n 1)"

  IFS=$'\t' read -r version url sha <<< "${line}"

  [[ "${version}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  [[ "${url}" == "${PD_URL_PREFIX}"* ]] || return 1
  [[ "${sha}" =~ ^[0-9a-fA-F]{128}$ ]] || return 1
  printf '%s\t%s\t%s\n' "${version}" "${url}" "${sha,,}"
}

# pinnedRelease <platform>: the same, for the version this script knows
pinnedRelease() {
  local base="${PD_URL_PREFIX}${PD_PIN_VERSION}"

  case "$1" in
    linux/x64)
      printf '%s\t%s\t%s\n' "${PD_PIN_VERSION}" \
        "${base}/linux-x64/proton-drive" "${PD_PIN_SHA512_X64}"
      ;;
    linux/arm64)
      printf '%s\t%s\t%s\n' "${PD_PIN_VERSION}" \
        "${base}/linux-arm64/proton-drive" "${PD_PIN_SHA512_ARM64}"
      ;;
    *) return 1 ;;
  esac
}

# installedVersion: version of the CLI in PD ("" if it doesn't run)
installedVersion() {
  local out

  out="$(runAs "${SYNC_USER}" "${PD}" version 2> /dev/null | head -n 1)"
  [[ "${out}" =~ @([0-9]+\.[0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}"
}

# downloadCli <version> <url> <sha512>
downloadCli() {
  local tmpdir rc

  tmpdir="$(mktemp -d)" || die "Could not create a temporary folder"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmpdir}'" EXIT

  log "Downloading the Proton Drive CLI $1..."
  log "  $2"

  if ! curl -fL --retry 2 --max-time 900 -# -o "${tmpdir}/proton-drive" "$2"; then
    die "Could not download the Proton Drive CLI from $2"
  fi

  log "Checking its SHA-512 checksum..."
  if ! echo "$3  ${tmpdir}/proton-drive" | sha512sum -c --status; then
    die "The downloaded Proton Drive CLI does not match Proton's SHA-512 \
checksum, so it was not installed. Try again later."
  fi

  # Try it as the sync user (so no root-owned CLI files are left behind)
  chmod 755 "${tmpdir}" "${tmpdir}/proton-drive"
  runAs "${SYNC_USER}" "${tmpdir}/proton-drive" version > /dev/null 2>&1
  rc=$?

  if [[ "${rc}" -eq 132 ]]; then
    die "$(cpuHelp)"
  elif [[ "${rc}" -ne 0 ]]; then
    die "The downloaded Proton Drive CLI does not start (exit status ${rc})."
  fi

  install -m 755 "${tmpdir}/proton-drive" "${PD_INSTALL}" \
    || die "Could not install ${PD_INSTALL}"
  rm -rf "${tmpdir}"
  trap - EXIT

  PD="${PD_INSTALL}"
  PD_VERSION="$1"
  log "Installed the Proton Drive CLI $1 to ${PD_INSTALL}."
}

loadCurrent() {
  local value

  if value="$(getEnvVar "${DEFAULTS_FILE}" PIVPN_SYNC_REMOTE)"; then
    REMOTE="${value}"
  fi

  if value="$(getEnvVar "${DEFAULTS_FILE}" PIVPN_SYNC_PRUNE)" \
    && [[ "${value}" == "0" ]]; then
    PRUNE=0
  fi
}

# defaultRemote: the folder the sync script uses when none is set
defaultRemote() {
  echo "/my-files/PiVPN/$(hostname -s)"
}

# remoteExists <path>
remoteExists() {
  pd filesystem info "$1" > /dev/null 2>&1
}

# parentOf </a/b/c>: /a/b (/ for a top-level path)
parentOf() {
  local parent="${1%/*}"
  echo "${parent:-/}"
}

# joinPath <folder> <name>: a slash inside a name is escaped as \/
joinPath() {
  echo "${1%/}/${2//\//\\/}"
}

# listFolders <path>: names of the folders in <path>, one per line, sorted
listFolders() {
  local typeOpt=() json

  [[ "$1" == /my-files* ]] && typeOpt=(--type folder)
  json="$(pd filesystem list --json "${typeOpt[@]}" "$1" 2> /dev/null)" \
    || return 1

  jq -r '.[]
    | select(.type == "folder")
    | if (.name | type) == "object"
      then (if .name.ok then .name.value else empty end)
      else .name end' <<< "${json}" | sort -f
}

# Add PROTON_DRIVE_CREDENTIALS_STORE=pass to ~/.profile? Not when it is
# there already, nor with a separate pass store (exporting PASSWORD_STORE_DIR
# would take over the user's own pass command)
wantProfileLine() {
  [[ "${#PASS_ENV[@]}" -eq 0 ]] \
    && ! grep -qs 'PROTON_DRIVE_CREDENTIALS_STORE=pass' "${SYNC_HOME}/.profile"
}

### Steps

stepIntro() {
  local text

  text="This copies the client profiles PiVPN makes (OpenVPN .ovpn and \
WireGuard .conf) to a folder in your Proton Drive, so you can get them from \
anywhere. Revoked clients' profiles go to the Proton Drive trash.

The setup:
  1. installs the official Proton Drive CLI (if needed)
  2. signs in to Proton Drive: you approve a link on any device
  3. asks which Proton Drive folder to use
  4. starts the sync

The profiles hold private keys: keep 2FA on the Proton account."

  if [[ -n "${REMOTE}" ]]; then
    text+="

Already set up here (folder ${REMOTE}). Continue to change it."
  fi

  ask --yes-button "Continue" --no-button "Cancel" "Proton Drive sync" "${text}"
}

stepUser() {
  local user

  chooseUser user "Profile owner" "Choose the user whose VPN client \
profiles (~/ovpns and ~/configs) are synced. PiVPN's install user owns them \
(press space to select):" || return 1

  SYNC_USER="${user}"
  SYNC_HOME="$(userHome "${user}")"
  SYNC_HOME="${SYNC_HOME%/}"

  [[ -n "${SYNC_HOME}" && -d "${SYNC_HOME}" ]] \
    || die "${user} has no home folder (${SYNC_HOME:-none})"
}

# findRelease <platform>: the release to install on this machine, from
# Proton's list (or the pinned one when the list can't be read). Without
# AVX2 only a "baseline" build works, which has no pinned fallback.
findRelease() {
  if [[ "$1" == "linux/x64" ]] && ! hasAvx2; then
    latestRelease "linux/x64-baseline"
  else
    latestRelease "$1" || pinnedRelease "$1"
  fi
}

stepCli() {
  local platform release="" version="" url="" sha="" current=""

  installPackages curl ca-certificates jq pass gnupg qrencode
  STOP_NOTE="Only the packages the setup needs (such as pass and gnupg) may \
have been installed."

  platform="$(cliPlatform)" \
    || die "Proton has no Linux build of its Drive CLI for $(uname -m)."

  PD="$(command -v proton-drive || true)"
  [[ -n "${PD}" ]] && current="$(installedVersion)"

  log "Looking up the newest Proton Drive CLI..."
  release="$(findRelease "${platform}")"
  IFS=$'\t' read -r version url sha <<< "${release}"

  if [[ -n "${current}" ]]; then
    # Installed and working: offer an update when there is one
    PD_VERSION="${current}"

    if [[ -n "${version}" ]] && versionGreater "${version}" "${current}"; then
      if ask --yes-button "Update" --no-button "Keep" "Proton Drive CLI" \
        "The Proton Drive CLI ${current} is installed (${PD}). Version \
${version} is available.

Update it? (Downloaded from proton.me, checked against Proton's SHA-512 \
checksum, installed to ${PD_INSTALL}.)"; then
        downloadCli "${version}" "${url}" "${sha}"
      fi
    else
      log "The Proton Drive CLI ${current} is installed (${PD})."
    fi
  else
    if [[ -z "${version}" ]]; then
      if [[ "${platform}" == "linux/x64" ]] && ! hasAvx2; then
        die "$(cpuHelp)"
      fi

      die "Could not find a Proton Drive CLI download for ${platform}."
    fi

    if [[ -n "${PD}" ]]; then
      ask --yes-button "Reinstall" --no-button "Cancel" "Proton Drive CLI" \
        "${PD} is installed but does not run on this machine.

Replace it with version ${version} from proton.me (checked against Proton's \
SHA-512 checksum, installed to ${PD_INSTALL})?" || return 1
    else
      ask --yes-button "Install" --no-button "Cancel" "Proton Drive CLI" \
        "The Proton Drive CLI (proton-drive) is not installed.

Download version ${version} for ${platform} from proton.me, check it against \
Proton's SHA-512 checksum, and install it to ${PD_INSTALL}?" || return 1
    fi

    downloadCli "${version}" "${url}" "${sha}"
  fi

  STOP_NOTE="The Proton Drive CLI is installed (${PD}); the sync has not been \
set up."
}

# A GPG key without passphrase and a pass store for the sync user, where the
# CLI keeps its Proton session (no desktop keyring on a server)
stepStore() {
  local fpr gpgId

  log "Preparing the encrypted Proton session store for ${SYNC_USER}..."

  if ! runAs "${SYNC_USER}" gpg --batch --list-secret-keys "${KEY_EMAIL}" \
    > /dev/null 2>&1; then
    log "Creating a GPG key for it (no passphrase, so the sync runs unattended)..."
    runAs "${SYNC_USER}" gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-gen-key "pivpn-proton-sync <${KEY_EMAIL}>" default default never \
      || die "Could not create a GPG key for ${SYNC_USER}"
  fi

  fpr="$(runAs "${SYNC_USER}" gpg --batch --with-colons --list-secret-keys \
    "${KEY_EMAIL}" 2> /dev/null | awk -F ':' '/^fpr:/ {print $10; exit}')"

  # Use the default store (~/.password-store) unless it already belongs to
  # another key; then use a separate one and leave that store alone
  STORE_DIR="${SYNC_HOME}/.password-store"

  if [[ -s "${STORE_DIR}/.gpg-id" ]]; then
    gpgId="$(cat "${STORE_DIR}/.gpg-id")"

    if ! grep -qxF -e "${KEY_EMAIL}" -e "${fpr:-none}" <<< "${gpgId}"; then
      STORE_DIR="${SYNC_HOME}/.local/share/pivpn-proton-sync/password-store"
      log "${SYNC_HOME}/.password-store uses another key, using ${STORE_DIR}."
    fi
  fi

  PASS_ENV=()
  [[ "${STORE_DIR}" != "${SYNC_HOME}/.password-store" ]] \
    && PASS_ENV=("PASSWORD_STORE_DIR=${STORE_DIR}")

  if [[ ! -s "${STORE_DIR}/.gpg-id" ]]; then
    runAs "${SYNC_USER}" "${PASS_ENV[@]}" pass init "${KEY_EMAIL}" > /dev/null \
      || die "Could not create the pass store ${STORE_DIR}"
  fi

  # Prove that a secret can be stored and read back without a passphrase
  # shellcheck disable=SC2016
  if ! runAs "${SYNC_USER}" "${PASS_ENV[@]}" bash -c \
    'printf "test\n" | pass insert -m -f pivpn-setup-selftest > /dev/null \
      && [[ "$(pass show pivpn-setup-selftest)" == "test" ]] \
      && pass rm -f pivpn-setup-selftest > /dev/null'; then
    die "The pass store ${STORE_DIR} does not work without a passphrase for \
${SYNC_USER}. Check: gpg --list-secret-keys ${KEY_EMAIL}"
  fi

  STOP_NOTE="The Proton Drive CLI is installed and ${SYNC_USER} has a session \
store; the sync has not been set up."
}

# Print the sign-in link and a QR code for it (when it fits the terminal)
printSignIn() {
  local url="$1" qr qrLines qrWidth

  tuiSize
  clearScreen
  qr="$(qrencode -t ansiutf8 -m 2 "${url}" 2> /dev/null)"
  qrLines="$(wc -l <<< "${qr}")"
  qrWidth="$(head -n 1 <<< "${qr}" | sed 's/\x1b\[[0-9;]*m//g' | wc -m)"

  echo

  if [[ -n "${qr}" ]] && [[ "${rows}" -ge $((qrLines + 10)) ]] \
    && [[ "${cols}" -ge "${qrWidth}" ]]; then
    printf '%s\n\n' "${qr}"
    log "Sign in to Proton Drive: scan the QR code, or open this link on any device:"
  else
    log "Sign in to Proton Drive: open this link on any device"
    log "(make the terminal larger to get a QR code instead):"
  fi

  echo
  echo "${url}"
  echo
  log "Sign in on Proton's page (with your 2FA code if you use one) and approve."
  log "Waiting for the approval, up to 10 minutes (Ctrl+C cancels)..."
}

# showLogin <log file>: reads the CLI's output during 'auth login --json',
# shows the link, and keeps any other output (errors) in <log file>
showLogin() {
  local line url=""

  while IFS= read -r line; do
    line="${line%$'\r'}"

    if [[ -z "${url}" && "${line}" == *'"signInUrl"'* ]]; then
      url="$(jq -r '.signInUrl // empty' <<< "${line}" 2> /dev/null)"

      if [[ "${url}" == https://* ]]; then
        printSignIn "${url}"
        continue
      fi
    fi

    if [[ -n "${line}" ]]; then
      echo "    ${line}"
      echo "${line}" >> "$1"
    fi
  done
}

# One sign-in attempt; true when signed in. On failure LOGIN_ERROR says why.
signInOnce() {
  local rc logFile

  LOGIN_ERROR=""
  logFile="$(mktemp)" || die "Could not create a temporary file"
  clearScreen
  log "Starting the Proton Drive sign-in..."

  # Ctrl+C stops the CLI, not this setup
  INTERRUPTED=0
  trap 'INTERRUPTED=1; echo' INT
  pd auth login --json 2>&1 | showLogin "${logFile}"
  rc="${PIPESTATUS[0]}"
  trap - INT

  LOGIN_ERROR="$(tail -n 4 "${logFile}" | cut -c 1-200)"
  rm -f "${logFile}"

  if [[ "${INTERRUPTED}" -eq 1 ]]; then
    LOGIN_ERROR="Cancelled with Ctrl+C."
    return 1
  elif [[ "${rc}" -ne 0 ]]; then
    LOGIN_ERROR="${LOGIN_ERROR:-The Proton Drive CLI stopped with exit status ${rc}.}"
    return 1
  fi

  log "Approved. Checking the new session..."

  if ! remoteExists /my-files; then
    LOGIN_ERROR="The sign-in finished, but Proton Drive still does not answer \
for ${SYNC_USER}."
    return 1
  fi
}

stepSignIn() {
  local choice

  log "Checking for an existing Proton Drive session..."

  if remoteExists /my-files; then
    ask --yes-button "Keep" --no-button "Sign in again" "Proton Drive" \
      "${SYNC_USER} is already signed in to Proton Drive on this machine.

Keep that session, or sign in again (for example with another Proton \
account)?"

    case $? in
      0) return 0 ;;
      1)
        log "Signing out the current session..."
        pd auth logout > /dev/null 2>&1
        ;;
      *) return 1 ;;
    esac
  fi

  ask --yes-button "Sign in" --no-button "Cancel" "Sign in to Proton Drive" \
    "Next, a sign-in link and a QR code appear on this screen.

  1. Open the link on any device, or scan the QR code.
  2. Sign in to Proton there (2FA too, if you use it).
  3. Approve, then come back: the setup goes on by itself.

Your password is only ever typed on Proton's own page, never here. The \
link is valid for 10 minutes." || return 1

  while ! signInOnce; do
    choose choice --cancel "Cancel" "Proton Drive sign-in" \
      "The sign-in did not complete:

${LOGIN_ERROR}

The link is valid for 10 minutes. Try again with a new link?" \
      "Retry" "Show a new sign-in link" || return 1
  done
}

# Folder browser; sets REMOTE, returns 1 to go back
browseFolder() {
  local cur="$1" names=() items=() choice name text

  # Start at the nearest folder that exists
  while [[ "${cur}" != "/" ]] && ! remoteExists "${cur}"; do
    cur="$(parentOf "${cur}")"
    [[ "${cur}" == "/shared-with-me" ]] && cur="/"
  done

  while true; do
    items=()

    if [[ "${cur}" == "/" ]]; then
      names=("my-files" "shared-with-me")
      items+=(1 "My files (/my-files)" 2 "Shared with me (/shared-with-me)")
      text="Your Proton Drive. Open a section:"
    else
      log "Reading ${cur}..."

      if ! mapfile -t names < <(listFolders "${cur}"); then
        msg "Proton Drive folder" "Could not read ${cur}."
        cur="$(parentOf "${cur}")"
        continue
      fi

      [[ "${#names[@]}" -eq 1 && -z "${names[0]}" ]] && names=()
      text="Folder: ${cur}

Use this folder for the profiles, or open one of its folders."

      if [[ "${cur}" != "/shared-with-me" ]]; then
        items+=("." "[ Use this folder ]" "+" "[ New folder here ]")
      else
        text="Folders other Proton accounts shared with you. Open one:"
      fi

      items+=(".." "[ Up one level ]")

      local i=0
      for name in "${names[@]}"; do
        i=$((i + 1))
        items+=("${i}" "${name}/")
      done
    fi

    choose choice --notags --cancel "Back" "Proton Drive folder" "${text}" \
      "${items[@]}" || return 1

    case "${choice}" in
      .)
        REMOTE="${cur}"
        REMOTE_EXISTS=1
        return 0
        ;;
      ..)
        cur="$(parentOf "${cur}")"
        ;;
      +)
        input name "New folder" "Name of the new folder in ${cur}:" \
          "PiVPN" || continue
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"

        if [[ -z "${name}" || "${name}" == */* ]]; then
          msg "New folder" "Enter a folder name (without /)."
          continue
        fi

        log "Creating $(joinPath "${cur}" "${name}")..."

        if pd filesystem create-folder "${cur}" "${name}" > /dev/null 2>&1; then
          cur="$(joinPath "${cur}" "${name}")"
        else
          msg "New folder" "Could not create \"${name}\" in ${cur}. It may \
already exist, or you may not be allowed to add folders there."
        fi
        ;;
      *)
        if [[ "${cur}" == "/" ]]; then
          cur="/${names[choice - 1]}"
        else
          cur="$(joinPath "${cur}" "${names[choice - 1]}")"
        fi
        ;;
    esac
  done
}

# Typed folder path; sets REMOTE, returns 1 to go back
typeFolder() {
  local value="$1" top

  while true; do
    input value "Proton Drive folder" "Type the folder path. It starts with \
/my-files (your own Drive) or /shared-with-me/<a folder shared with you>. \
Missing folders are created by the first sync.

Example: $(defaultRemote)" "${value}" || return 1

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    while [[ "${value}" == *//* ]]; do value="${value//\/\//\/}"; done
    [[ "${value}" != "/" ]] && value="${value%/}"

    if [[ "${value}" =~ ^/my-files(/.+)?$ ]]; then
      REMOTE="${value}"
      return 0
    fi

    if [[ "${value}" =~ ^/shared-with-me/[^/]+ ]]; then
      top="${value#/shared-with-me/}"
      top="/shared-with-me/${top%%/*}"
      log "Checking ${top}..."

      if remoteExists "${top}"; then
        REMOTE="${value}"
        return 0
      fi

      msg "Proton Drive folder" "${top} was not found: nothing by that name \
is shared with this Proton account."
      continue
    fi

    msg "Proton Drive folder" "The path must start with /my-files or with \
/shared-with-me/<shared folder>."
  done
}

stepFolder() {
  local choice default label

  default="${REMOTE:-$(defaultRemote)}"
  label="Default"
  [[ -n "${REMOTE}" ]] && label="Current"

  while true; do
    choose choice --default "${label}" "Proton Drive folder" "Which Proton \
Drive folder receives the profiles? The OpenVPN profiles go into its \
subfolder ovpns, the WireGuard ones into configs." \
      "${label}" "${default}" \
      "Browse" "Pick a folder in your Proton Drive" \
      "Type" "Type a folder path" || return 1

    case "${choice}" in
      Default | Current)
        REMOTE="${default}"
        break
        ;;
      Browse)
        browseFolder "${default}" && break
        ;;
      Type)
        typeFolder "${default}" && break
        ;;
    esac
  done

  log "Checking ${REMOTE}..."

  if remoteExists "${REMOTE}"; then
    REMOTE_EXISTS=1
  else
    REMOTE_EXISTS=0
  fi
}

stepPrune() {
  local defaultNo=()

  [[ "${PRUNE}" -eq 0 ]] && defaultNo=(--no)

  ask "${defaultNo[@]}" "Revoked clients" "When you revoke or remove a VPN \
client, move its profile in Proton Drive to the trash?

Recommended: the profile holds the client's private key. Trashed files can \
still be restored from the Proton Drive trash."

  case $? in
    0) PRUNE=1 ;;
    1) PRUNE=0 ;;
    *) return 1 ;;
  esac
}

stepConfirm() {
  local text folderNote="" pruneLine profileNote=""

  [[ "${REMOTE_EXISTS}" -eq 0 ]] && folderNote=" (new)"

  pruneLine="moved to the Proton Drive trash"
  [[ "${PRUNE}" -eq 0 ]] && pruneLine="left in Proton Drive"

  wantProfileLine \
    && profileNote=", and adds PROTON_DRIVE_CREDENTIALS_STORE=pass to \
~/.profile so proton-drive works in your shell too"

  text="Ready to set up the Proton Drive sync:

  User:     ${SYNC_USER} (profiles in ~/ovpns and ~/configs)
  CLI:      ${PD_VERSION:-installed}, signed in
  Folder:   ${REMOTE}${folderNote}
  Revoked:  ${pruneLine}
  Runs:     when a profile changes, and once a day

This installs /usr/local/bin/pivpn-proton-sync, its systemd units and \
${DEFAULTS_FILE}${profileNote}."

  ask --yes-button "Install" --no-button "Cancel" "Set up the Proton Drive sync" \
    "${text}"
}

### Install

applySettings() {
  local unit="pivpn-proton-sync@${SYNC_USER}" dir since rc journal manualLine=""

  log "Installing the Proton Drive sync..."

  if ! install -m 755 "${SCRIPT_DIR}/pivpn-proton-sync" /usr/local/bin/ \
    || ! install -m 644 "${SCRIPT_DIR}/pivpn-proton-sync@.service" \
      "${SCRIPT_DIR}/pivpn-proton-sync@.path" \
      "${SCRIPT_DIR}/pivpn-proton-sync@.timer" /etc/systemd/system/; then
    die "Could not install the sync script and units"
  fi

  if [[ ! -f "${DEFAULTS_FILE}" ]]; then
    install -m 644 "${SCRIPT_DIR}/pivpn-proton-sync.default" "${DEFAULTS_FILE}" \
      || die "Could not write ${DEFAULTS_FILE}"
  fi

  setEnvVar "${DEFAULTS_FILE}" PIVPN_SYNC_REMOTE "$(systemdQuote "${REMOTE}")"
  setEnvVar "${DEFAULTS_FILE}" PIVPN_SYNC_PRUNE "${PRUNE}"
  setEnvVar "${DEFAULTS_FILE}" PROTON_DRIVE_BIN "${PD}"

  if [[ "${#PASS_ENV[@]}" -gt 0 ]]; then
    setEnvVar "${DEFAULTS_FILE}" PASSWORD_STORE_DIR "$(systemdQuote "${STORE_DIR}")"
  else
    setEnvVar "${DEFAULTS_FILE}" PASSWORD_STORE_DIR ""
  fi

  # The folders the path unit watches must exist
  for dir in "${SYNC_HOME}/ovpns" "${SYNC_HOME}/configs"; do
    [[ -d "${dir}" ]] || runAs "${SYNC_USER}" mkdir -p "${dir}" \
      || die "Could not create ${dir}"
  done

  # The units assume /home/<user>; point the path unit elsewhere if needed
  if [[ "${SYNC_HOME}" != "/home/${SYNC_USER}" ]]; then
    mkdir -p "/etc/systemd/system/${unit}.path.d"
    printf '[Path]\nPathChanged=\nPathChanged=%s/ovpns\nPathChanged=%s/configs\n' \
      "${SYNC_HOME}" "${SYNC_HOME}" \
      > "/etc/systemd/system/${unit}.path.d/home.conf"
  fi

  # So that 'proton-drive' finds the session in the user's own shell
  if wantProfileLine; then
    printf '\n%s\n%s\n' \
      "# Added by the PiVPN Proton Drive setup: proton-drive keeps its session in pass" \
      "export PROTON_DRIVE_CREDENTIALS_STORE=pass" \
      | runAs "${SYNC_USER}" tee -a "${SYNC_HOME}/.profile" > /dev/null
  fi

  systemctl daemon-reload
  systemctl reset-failed "${unit}.service" 2> /dev/null
  systemctl enable --now "${unit}.path" "${unit}.timer" \
    || die "Could not enable ${unit}.path and ${unit}.timer"

  log "Running the first sync (this takes a little while)..."
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl start "${unit}.service"
  rc=$?
  journal="$(journalctl -u "${unit}.service" --since "${since}" -o cat \
    --no-pager 2> /dev/null | grep '^pivpn-proton-sync' | tail -n 4)"

  # With a separate pass store, the user's own shell needs both variables
  if [[ "${#PASS_ENV[@]}" -gt 0 ]]; then
    manualLine="

To run proton-drive yourself (your own pass store is left alone):
  PROTON_DRIVE_CREDENTIALS_STORE=pass PASSWORD_STORE_DIR=${STORE_DIR} proton-drive"
  fi

  if [[ "${rc}" -eq 0 ]]; then
    msg "Proton Drive sync is set up" "The Proton Drive sync is running:
  ~/ovpns, ~/configs  ->  ${REMOTE}/ovpns, configs

First sync:
${journal:-  (no output)}

Profiles are uploaded about 15 seconds after 'pivpn add', and a daily \
run catches anything missed. Log:
  journalctl -u ${unit}.service${manualLine}"
  else
    msg "Proton Drive: first sync failed" "The sync is installed and \
enabled, but the first run failed:

${journal:-(no log output; see journalctl -u ${unit}.service)}

To retry after fixing the cause:
  sudo systemctl start ${unit}.service
  journalctl -u ${unit}.service -n 20"
  fi
}

main() {
  needTerminal
  elevate "$@"
  needWhiptail
  needSystemd

  [[ -f "${SCRIPT_DIR}/pivpn-proton-sync" ]] \
    || die "pivpn-proton-sync is missing next to this script (${SCRIPT_DIR})"

  loadCurrent

  wizard stepIntro stepUser stepCli stepStore stepSignIn stepFolder \
    stepPrune stepConfirm

  applySettings
}

main "$@"
