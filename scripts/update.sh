#!/bin/bash
# PiVPN: update the PiVPN scripts from the git repository they came from.
#
# The installer clones the repository to /usr/local/src/pivpn and symlinks
# /opt/pivpn and /usr/local/bin/pivpn into it, so updating the scripts only
# means moving that checkout to the newest commit of its branch. Files that
# the installer generated from templates (server.conf, wg0.conf, Default.txt,
# setupVars.conf, client profiles) live elsewhere and are not touched.
#
# The repository is either a git server (installed with the standalone
# installer) or a local clone (installed with ./install.sh from that clone).
# A local clone is not updated from its server here: 'git pull' it first.

### Constants
pivpnFilesDir="/usr/local/src/pivpn"

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

# A local clone is usually owned by a normal user while this runs as root,
# which git refuses ("dubious ownership"). Store an exception for exactly
# that repository on the upload-pack side, where a local fetch checks it.
# Also prints the path of the clone, or nothing for a git server.
configureOrigin() {
  local originUrl clonePath

  originUrl="$(git remote get-url origin)"

  case "${originUrl}" in
    file://*)
      clonePath="${originUrl#file://}"
      ;;
    /*)
      clonePath="${originUrl}"
      ;;
    *)
      clonePath=""
      ;;
  esac

  if [[ -z "${clonePath}" ]]; then
    git config --unset remote.origin.uploadpack 2> /dev/null
    return 0
  fi

  if [[ ! -d "${clonePath}" ]]; then
    err "::: The local clone ${clonePath} these scripts were installed from no longer exists"
    err "::: Point the update at a repository with: pivpn update --url <git url or path>"
    exit 1
  fi

  if [[ "${clonePath}" == *"'"* ]]; then
    err "::: The path of the clone must not contain a single quote: ${clonePath}"
    exit 1
  fi

  git config remote.origin.uploadpack \
    "git -c safe.directory='${clonePath}/.git' upload-pack"
  echo "${clonePath}"
}

scriptusage() {
  echo "::: Updates the PiVPN scripts from the git repository they were"
  echo "::: installed from (${pivpnFilesDir})"
  echo ":::"
  echo -n "::: Usage: pivpn <-up|update> [-b|--branch <name>] "
  echo "[-u|--url <url or path>] [-t|test] [-h|help]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]              Update from the branch currently checked out"
  echo ":::  -b, --branch <name> Update from (and switch to) another branch"
  echo ":::  -u, --url <url>     Switch to another repository first (a git URL,"
  echo ":::                      or the path of a local clone)"
  echo ":::  -t, test            Same as '--branch test'"
  echo ":::  -h, help            Show this usage dialog"
}

### Script
branch=""
url=""

while [[ "$#" -gt 0 ]]; do
  case "${1}" in
    -t | test)
      branch="test"
      ;;
    -b | --branch | --gitbranch)
      if [[ -z "${2}" ]]; then
        err "::: Missing branch name for ${1}"
        exit 1
      fi

      branch="${2}"
      shift
      ;;
    -u | --url | --giturl)
      if [[ -z "${2}" ]]; then
        err "::: Missing repository URL for ${1}"
        exit 1
      fi

      url="${2}"
      shift
      ;;
    -h | help)
      scriptusage
      exit 0
      ;;
    *)
      err "::: Unknown option '${1}'"
      scriptusage
      exit 1
      ;;
  esac

  shift
done

if [[ "${EUID}" -ne 0 ]]; then
  err "::: The update must run as root (use 'pivpn update')"
  exit 1
fi

if ! command -v git > /dev/null; then
  err "::: git is not installed"
  exit 1
fi

if ! git -C "${pivpnFilesDir}" rev-parse --git-dir &> /dev/null; then
  err "::: ${pivpnFilesDir} is not a git checkout, reinstall PiVPN to update"
  exit 1
fi

cd "${pivpnFilesDir}" || exit 1

if [[ -n "${url}" ]]; then
  # A local clone given as a path: absolute, and as file:// so the fetch
  # can stay shallow
  if [[ -d "${url}" ]]; then
    url="file://$(readlink -f "${url}")"
  fi

  echo "::: Switching the repository to ${url}"
  git remote set-url origin "${url}" || exit 1
fi

clonePath="$(configureOrigin)" || exit 1

if [[ -n "${clonePath}" ]]; then
  echo "::: Updating from the local clone ${clonePath}: if it should match your"
  echo ":::   git server, run 'git pull' in it first."
fi

if [[ -z "${branch}" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"

  if [[ "${branch}" == "HEAD" ]]; then
    err "::: The checkout is not on a branch, pass one with --branch"
    exit 1
  fi
fi

echo "::: Updating PiVPN scripts from $(git remote get-url origin)," \
  "branch '${branch}'"

before="$(git rev-parse --short HEAD)"

# The installer clones with --depth 1, so keep the checkout shallow
if ! git fetch -q --depth 1 origin "${branch}"; then
  err "::: Could not fetch branch '${branch}'"
  exit 1
fi

if ! git diff --quiet HEAD; then
  echo "::: These local changes in ${pivpnFilesDir} will be discarded:"
  git diff --stat HEAD | sed 's/^/:::   /'
fi

if ! git checkout -q --force -B "${branch}" FETCH_HEAD; then
  err "::: Could not check out '${branch}'"
  exit 1
fi

after="$(git rev-parse --short HEAD)"

if [[ "${before}" == "${after}" ]]; then
  echo "::: PiVPN scripts are already up to date (${after})"
else
  echo "::: PiVPN scripts updated: ${before} -> ${after}"
  git log -1 --format=':::   %h %s (%cs)'
fi

echo -n "::: Changes to templates under ${pivpnFilesDir}/files only apply "
echo "to new installs; existing server and client configs are unchanged."
