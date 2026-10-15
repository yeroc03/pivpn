# Installing PiVPN (yeroc03 fork)

There are two ways to install, and both end in the same place: the PiVPN
scripts in `/usr/local/src/pivpn` (root-owned), the `pivpn` command, and your
VPN configuration under `/etc`.

| | Route 1: from a clone | Route 2: standalone installer |
|---|---|---|
| You run | `./install.sh` inside a clone of this repository | A downloaded (or piped) `install.sh` |
| Scripts come from | That clone's last commit | The git URL in the installer (`pivpnGitUrl`) or `--giturl` |
| Git server needed during install | No | Yes, readable without credentials |
| Works with a private repository (e.g. on your Gitea) | Yes | Only if root can clone it |
| `pivpn update` fetches from | Your clone (`git pull` it first) | The git URL |

Route 1 is the one to use when the repository lives on a private server, or
when you want to install exactly what you have checked out.

Both routes still need internet access for the distribution's packages
(`apt`) and, for OpenVPN, the EasyRSA release that the installer downloads from
OpenVPN's GitHub releases and checks against a pinned SHA-256.

---

## Requirements

- Debian 11–13, Raspberry Pi OS, or Ubuntu 20.04–26.04 LTS (other Debian-based
  systems may work; the installer warns).
- A user with `sudo` rights. Run the installer as that user, not as root; it
  calls `sudo` itself and asks which user will own the client profiles.
- A fixed LAN address for the machine (a DHCP reservation is fine).

---

## Route 1: install from a clone

```bash
sudo apt install -y git

# Clone from wherever the repository lives (any URL git understands):
git clone https://github.com/yeroc03/pivpn.git pivpn
#   git clone https://gitea.example.lan/yeroc03/pivpn.git pivpn
#   git clone ssh://git@gitea.example.lan:2222/yeroc03/pivpn.git pivpn

cd pivpn
git checkout master        # optional: any branch, tag or commit
./install.sh               # interactive
```

What happens:

- The installer notices it is running from a clone and installs that clone's
  **last commit**. It prints the branch and commit it is using.
- Uncommitted changes are **not** installed. The installer lists them and, when
  interactive, asks whether to go on. Commit first if you want them included.
- No git server is contacted: the clone is copied into `/usr/local/src/pivpn`
  with git, locally. Your credentials for the server are never needed by root.
- `/usr/local/src/pivpn` remembers the clone as its origin, so
  `pivpn update` later pulls from it (see [Updating](#updating)). Keep the clone.

Notes:

- Running `bash auto_install/install.sh` inside the clone is the same as
  `./install.sh`.
- The clone can be anywhere you own (e.g. `~/pivpn`). The installer, and later
  `pivpn update`, run code from it as root, so keep it writable only by you.
- It must be a normal git clone (with a `.git` folder). A downloaded tarball of
  the repository is not detected as a clone and falls back to Route 2.

---

## Route 2: standalone installer

Download the installer on its own and run it. It clones the repository named
by `pivpnGitUrl` in `auto_install/install.sh` (currently
`https://github.com/yeroc03/pivpn.git`).

```bash
curl -fsSL https://raw.githubusercontent.com/yeroc03/pivpn/master/auto_install/install.sh -o pivpn-install.sh
bash pivpn-install.sh
```

Piping works too: `curl -fsSL <url> | bash`.

**From another server**, point both the download and the clone at it.
For Gitea, a file's raw URL is
`https://<gitea>/<owner>/<repo>/raw/branch/<branch>/<path>`:

```bash
curl -fsSL https://gitea.example.lan/yeroc03/pivpn/raw/branch/master/auto_install/install.sh -o pivpn-install.sh
bash pivpn-install.sh --giturl https://gitea.example.lan/yeroc03/pivpn.git
```

Instead of `--giturl` you can set `PIVPN_GIT_URL` (and `PIVPN_GIT_BRANCH`) in
the environment, or change the `pivpnGitUrl` default in
`auto_install/install.sh` and commit it, so the installer served from your
server defaults to your server.

The repository must be readable **without credentials** for this route,
because the clone runs as root. For a private repository use Route 1.

---

## Unattended installs

Every installer option works with both routes. Put the answers in a file and
pass it with `--unattended`; `examples/` has complete samples. A minimal
WireGuard file:

```bash
IPv4dev=ens18
install_user=yeroc03
VPN=wireguard
pivpnPORT=51820
pivpnDNS1=192.168.11.53
pivpnHOST=myhome.duckdns.org
UNATTUPG=1
```

```bash
./install.sh --unattended ~/pivpn-wireguard.conf
```

Anything left out gets PiVPN's default (a random free subnet for `pivpnNET`,
the public IP for `pivpnHOST`). `IPv4dev` and `install_user` may only be left
out when the machine has exactly one active interface and one normal user.

## WireGuard and OpenVPN side by side

Run the installer a second time. Interactively, choose **Reconfigure** in the
"Existing Install Detected" menu and pick the other protocol. Unattended, pass
the other protocol's answer file. The first protocol is left as it is, and the
`pivpn` command switches to `pivpn wg ...` / `pivpn ovpn ...`.

---

## Updating

`pivpn update` moves `/usr/local/src/pivpn` to the newest commit of its branch
in its origin. With one protocol installed, the command is `pivpn wg update` or
`pivpn ovpn update`.

| Installed with | To update |
|---|---|
| Route 1 (clone) | `cd ~/pivpn && git pull && pivpn update` |
| Route 2 (standalone) | `pivpn update` |

Options:

```bash
pivpn update --branch test                                   # follow another branch
pivpn update --url ~/pivpn                                   # update from a clone from now on
pivpn update --url https://gitea.example.lan/yeroc03/pivpn.git   # or from a server (anonymous read)
```

An update replaces the scripts only. Your `server.conf`, `wg0.conf`, client
profiles and settings are not touched; changes to the templates under
`files/` take effect for new installs and new (or regenerated) profiles.

---

## Moving the repository (e.g. GitHub → Gitea)

1. Create the repository on Gitea (empty, or with Gitea's *New Migration*
   from GitHub) and push to it from any clone:
   `git remote set-url origin <gitea url> && git push --all && git push --tags`.
2. On each PiVPN machine installed from a clone, point the clone at Gitea:
   `cd ~/pivpn && git remote set-url origin <gitea url>`. `pivpn update` keeps
   using the clone, so nothing else changes.
3. On a machine installed with the standalone installer, either
   `pivpn update --url <gitea url>` (anonymous read needed), or clone from
   Gitea and run `pivpn update --url ~/pivpn`.
4. Optionally change `pivpnGitUrl` in `auto_install/install.sh` (Route 2's
   default) and the URLs in `README.md` / this file, then commit.

After that the GitHub copy can be deleted.

---

## Installer options

| Option | Meaning |
|---|---|
| `--unattended <file>` | No dialogs; answers come from `<file>` |
| `--giturl <url>` | Clone the scripts from `<url>` (also overrides a clone run) |
| `--gitbranch <name>` | Check out `<name>` after cloning |
| `--reconfigure` | Reinstall over an existing install with new settings |
| `--noipv6` | Disable IPv6 support and the forced IPv6 route |
| `--ignoreipv6leak` | Don't force client IPv6 into the tunnel |
| `--use-pihole` | Use a local Pi-hole as the VPN clients' DNS |
| `--show-unsupported-nics` | List every network interface, not only active ones |
| `--skip-space-check` | Skip the free disk space check |
| `PIVPN_GIT_URL`, `PIVPN_GIT_BRANCH` | Environment equivalents of `--giturl`, `--gitbranch` |

## What goes where

| Path | Contents |
|---|---|
| `/usr/local/src/pivpn` | Root-owned git copy of the repository the scripts run from |
| `/opt/pivpn` → `/usr/local/src/pivpn/scripts` | Scripts used by the `pivpn` command |
| `/usr/local/bin/pivpn` | The `pivpn` command |
| `/etc/pivpn/<protocol>/setupVars.conf` | Installation settings |
| `/etc/openvpn`, `/etc/wireguard` | Server configuration, keys, PKI |
| `~<user>/ovpns`, `~<user>/configs` | OpenVPN and WireGuard client profiles |

## Uninstalling

`pivpn uninstall` removes one protocol at a time (it asks which when both are
installed; `pivpn wg uninstall` / `pivpn ovpn uninstall` name it directly).
Removing the last one also removes the scripts. To reinstall later, run
`./install.sh` from your clone again.

## Extras

Optional add-ons in `extras/`, not installed by the installer; each folder has
a `README.md` with setup steps:

| Folder | What it does |
|---|---|
| `extras/duckdns-update/` | Keeps your DuckDNS name pointing at your home IP (systemd timer, optional Gotify alerts) |
| `extras/proton-drive-sync/` | Mirrors the client profiles to Proton Drive |
