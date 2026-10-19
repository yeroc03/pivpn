# yeroc03/pivpn: issues found and fixes

This fork is [pivpn/pivpn](https://github.com/pivpn/pivpn) `master` at `aa96de7`
(November 2025) plus:

1. the nine commits on upstream's unreleased `test` branch (up to `73ec0b7`,
   August 30, 2026), cherry-picked unchanged;
2. the fixes below, found while auditing the installer and scripts for an
   Ubuntu Server 24.04 / 26.04 LTS VM that runs WireGuard and OpenVPN side by
   side and serves Linux Mint (NetworkManager) clients.

Every fix was exercised on Ubuntu 24.04 (OpenVPN 2.6.19, GNU tar 1.35) and the
OpenVPN-specific ones again against Ubuntu 26.04's OpenVPN 2.7.0 build; see
[How this was tested](#how-this-was-tested).

---

## Summary

| # | Problem | Who hits it | Effect | Fixed in |
|---|---|---|---|---|
| A | EasyRSA extraction fails with GNU tar 1.35 | Every new OpenVPN install | Install aborts | upstream `5ce09ed` (cherry-picked) + `643da7e` |
| B | Server and profiles pin `cipher AES-256-CBC` | OpenVPN 2.6+, NetworkManager clients | NM clients rejected | `9225d72` |
| 1 | `pivpn revoke` makes the CRL unreadable | OpenVPN, after the first revoke | **All clients refused** until a restart | `2d9beb1` |
| 2 | sudo-rs drops the server certificate lifetime | Ubuntu 25.10+/26.04, installer run as a normal user | Server cert expires after 825 days, not 10 years | `eb0c01e` |
| 3 | `pivpn add -o` re-registers the client | OpenVPN | Client IP changes, duplicate config lines, new key | `0e39323` |
| 4 | `pivpn -d` checks the wrong OpenVPN unit | OpenVPN on Debian/Ubuntu | Crashed server reported as running | `b203fd7` |
| 5 | Installer steps race each other without a terminal | cloud-init, `ssh host bash`, CI | apt lock errors, wrong branch checked out | `9e51938` |
| 6 | Installer edits its own git checkout | OpenVPN 2.5 mode (the default) | Breaks later updates of the checkout | `d1590c5` |
| 7 | Ubuntu 26.04 treated as untested | Ubuntu 26.04 | "Untested OS" stop | `2d7b080` |
| 8 | `pivpn update` does nothing | Everyone | No way to update the scripts | `dbdda10` |
| 9 | EasyRSA download unverified, every failure reported as "download" | Every OpenVPN install | Misleading errors, no integrity check | `643da7e` |
| 10 | A fork's installer installs upstream's scripts | Anyone installing from a fork | Fork fixes silently not installed | `3607bf4` |
| 11 | Small script bugs, temp files left in `/tmp` | Edge cases | See below | `0e39323`, `ae50822`, `deacd94` |
| 12 | CI | Fork maintenance | Travis is gone; release jobs would run on the fork | `0fd1373` |
| 13 | Installer can only install from a fixed git URL | Self-hosted or private repositories | Fork tied to GitHub | `1077820`, `9fcdc4f` |
| 14 | `setupVars.conf` unreadable by the installing user | Installer run as a normal user (the usual way) | Second protocol not detected; dual `pivpn` command not linked | `cf9c898` |
| 15 | Extras set up by hand, file by file | Anyone using `extras/` | Several manual steps, tokens typed into config files | setup menu (this change) |

A and B are the two problems already written up in this project
(`pivpn-easyrsa-tar-fix.md`, `pivpn-openvpn-cipher-fix.md`). Everything from 1
onward is new.

---

## A and B: the two known issues

**A. EasyRSA extraction (`--one-top-level` with an absolute path).** Upstream
fixed this on its `test` branch (`5ce09ed`) with the "create the directory,
then `tar -C`" variant from the earlier write-up; that commit is included. The
bug was reproduced here on Ubuntu 24.04's GNU tar 1.35 (same `EXDEV` errors as
the original log), and the fixed command extracts correctly. Fix 9 below adds a
checksum and separate error messages on top.

**B. Cipher.** Both templates now carry
`data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305` instead of
`cipher AES-256-CBC`. Two deliberate differences from the earlier write-up's
server-side patch:

- **No CBC fallback on the server.** Every profile made by a fresh install
  comes from the fixed template, so nothing needs CBC. A non-AEAD cipher in the
  server's list also turns off kernel data channel offload (DCO) in OpenVPN
  2.6/2.7 ("cipher 'AES-256-CBC' in --data-ciphers is not supported by
  ovpn-dco, disabling data channel offload"), which Ubuntu 26.04's kernel can
  otherwise use. Only add `:AES-256-CBC` on an *existing* server that still
  has old profiles in the field, as the earlier write-up describes.
- **Traditional (non-2.5) mode.** That mode exists for pre-2.5 clients, which
  don't know `data-ciphers` and would refuse the profile. Its profiles get
  `cipher AES-256-GCM` instead: 2.4 clients accept it, the server accepts it,
  and NetworkManager turns it into `--data-ciphers AES-256-GCM`.

---

## New issues

### 1. `pivpn revoke` locks every client out (CRL permissions)

- **Symptom:** after revoking one client, *no* client can connect. The server
  logs `VERIFY WARNING: depth=1, unable to get certificate CRL` /
  `VERIFY ERROR: CRL not loaded`. A restart (or reboot) appears to fix it, until
  the next revoke.
- **Cause:** EasyRSA 3.2 writes `pki/crl.pem` as `root:root 0600`. The
  installer copies it to `/etc/openvpn/crl.pem` and chowns it to `openvpn`, but
  `removeOVPN.sh` used `cp -a`, which copies the `root 0600` attributes too.
  OpenVPN runs as `openvpn` after start-up and re-reads the CRL when its mtime
  changes; the read fails, OpenVPN 2.6/2.7 has already dropped the old CRL and
  keeps CRL checking on, so verification fails for everyone.
- **Fix:** `install -m 0644` the CRL (it contains no secrets). `pivpn -d` now
  also checks that the openvpn user can read it and offers to fix it, which
  repairs existing installs that already revoked a client.
- **Verified:** reproduced with upstream's `cp -a` (all connections refused),
  then fixed: after `pivpn revoke`, other clients connect and the revoked one
  is rejected.

### 2. Ubuntu 26.04: server certificate silently gets 825 days instead of 10 years

- **Cause:** the installer ran
  `EASYRSA_CERT_EXPIRE=3650 sudo -E ./easyrsa build-server-full ...`. Ubuntu
  25.10 and 26.04 use **sudo-rs** as `sudo`, which does not support `-E`
  ("preserving the entire environment is not supported, '-E' is ignored"), so
  the variable never reaches EasyRSA and it applies its default of 825 days.
  Nothing fails at install time; about 27 months later every OpenVPN client
  stops connecting.
- **Fix:** pass `--days=3650` to EasyRSA as an option, and stop using `-E`
  altogether (nothing needs the caller's environment, and a stray `EASYRSA_*`
  variable shouldn't leak into the PKI).
- **Verified:** with EasyRSA 3.2.3, no variable gives an end date 825 days out,
  `--days=3650` gives 10 years; confirmed sudo-rs 0.2.13 (26.04) ignores `-E`.
  Running the installer as root (`sudo bash install.sh`) was never affected.

### 3. `pivpn add -o` (regenerate a profile) re-registers the client

The earlier cipher write-up recommends `pivpn ovpn add -o -n <client>` to
rebuild profiles from the fixed template. Upstream, that command also:

- appended a second `ifconfig-push` line with a **new** IP to the client's ccd
  file (the client's static IP changed; the old one stayed reserved) and added
  a duplicate Pi-hole hosts entry;
- minted a **new** tls-crypt-v2 client key and metadata line, so the profile on
  the device was no longer the one the server considered current;
- refused to run once the subnet was full, and didn't check the client still
  had a valid certificate.

**Fix:** `-o` now requires a valid certificate in `index.txt`, reuses the
existing tls-crypt-v2 key and ccd entry, and only allocates an IP for a client
that has none. IP allocation moved into a function that matches whole addresses
(`10.8.0.2` no longer matches `10.8.0.25`), and new clients get their ccd file
written fresh rather than appended to. **Verified:** regenerating a client
leaves its key, ccd file and IP untouched, the profile still connects, and `-o`
on a revoked or unknown name exits with an error.

### 4. `pivpn -d` says OpenVPN is running when it has crashed

On Debian/Ubuntu `openvpn.service` is a placeholder (`Type=oneshot`,
`ExecStart=/bin/true`) that stays "active" whatever happens to the real
`openvpn@server` instance. `pivpn -d` checked the placeholder. It now checks
(and restarts) `openvpn@server`, and still checks that `openvpn.service` is
enabled, since that is what the installer enables.

### 5. Installer races itself when there is no terminal

The installer's `spinner()` waited for background jobs by polling `ps a`, which
only lists processes attached to a terminal. With no terminal (cloud-init,
`ssh host 'bash -s'`, CI), it returned immediately, so the next step started
while the previous was still running: `apt-get install` against a running
`apt-get update` ("rename failed ... partial", "Could not get lock"), or
`git checkout <branch>` before the clone had finished ("pathspec did not
match"). Both happened in testing. It now polls `/proc/<pid>`, which also works
for the root-owned `sudo` child.

### 6. The installer modifies its own git checkout

For OpenVPN 2.5 mode, `confOpenVPN()` ran `sed -i` on
`/usr/local/src/pivpn/files/.../Default.txt` (the template inside the git
checkout) instead of on the installed copy. That leaves the checkout dirty, so
a later `git pull` conflicts or quietly reverts. The edit now applies to
`/etc/openvpn/easy-rsa/pki/Default.txt` in `confOVPN()`; the checkout stays
clean (verified with `git status` after an install).

### 7. Ubuntu 26.04 LTS (resolute) support

26.04 was missing from the supported list, so the installer stopped at
"Untested OS". Added. Checked against the resolute archive: every package the
installer pulls in exists (openvpn 2.7.0, wireguard-tools 1.0.20250521,
grepcidr, bsdmainutils, iptables-persistent, bind9-dnsutils, net-tools,
whiptail), the OpenVPN systemd layout is unchanged (`openvpn.service` +
generator + `openvpn@.service`), and every coreutils call the scripts make
(`df -Pk`, `sort -V`, `cut`, `install -Dm`, `ln -sfT`, `shuf -i`, `date`,
`base64 -w 0`, `tr`, `mktemp`, ...) gives the same output under the Rust
coreutils (uutils 0.10.0) that 26.04 uses by default. The server config also
runs unchanged on OpenVPN 2.7.0 (two harmless notices, listed under
[Not changed](#found-but-not-changed)).

### 8. `pivpn update` was a no-op

Upstream's `update.sh` exits on its first lines ("updating functionality ...
temporarily disabled"); the code behind that exit cloned into `/etc/.pivpn`,
copied over the `/opt/pivpn` symlink and had its branch tests inverted.

The installer already symlinks `/opt/pivpn` and `/usr/local/bin/pivpn` into
the git checkout at `/usr/local/src/pivpn`, so updating the scripts only means
moving that checkout to the newest commit. `pivpn update` (also
`pivpn wg update` / `pivpn ovpn update`) now does that, shallow like the
installer's clone, and reports the old and new commit. `--branch <name>`
switches branch and `--url <repo>` switches repository (e.g. upstream to this
fork). Generated configs and client profiles are untouched; template changes
only reach new installs and new or regenerated profiles.

### 9. EasyRSA download: no integrity check, one error for everything

`curl | tar` meant a failed download, a corrupted file and the tar bug (A) all
surfaced as "Failed to download EasyRSA". Worse, by then the installer had
already deleted the existing `server.conf`, `ccd/` and `easy-rsa/` (they are in
the `/etc/openvpn_<date>.tar.gz` backup, but the server is down). The tarball
is now downloaded first, before anything is removed, to a temporary file,
checked against a pinned SHA-256
(`577d9a0f…cd851e3`, EasyRSA-3.2.3.tgz as served by the OpenVPN GitHub
release), extracted, and each step has its own error. Set `easyrsaSha256=""`
in `install.sh` to skip the check when trying another EasyRSA version.

### 10. Installing from a fork still installed upstream

The installer clones its scripts and templates from `pivpnGitUrl` into
`/usr/local/src/pivpn` and runs everything from there, whichever copy of
`install.sh` you started. In a fork that default still pointed at
`pivpn/pivpn`, so none of the fork's fixes would have been installed unless
`--giturl` was passed. The standalone installer's default now points at
`yeroc03/pivpn`; installing from a clone (13) doesn't use it at all.

### 11. Smaller fixes

- `makeOVPN.sh`: the iOS `.ovpn12` export read the never-set
  `PASSWD_UNESCAPED` for the key password; the "certificate/key not found"
  errors exited with status 0.
- `makeCONF.sh`: `read` without `-r` (shellcheck SC2162).
- `install.sh` left its temporary setupVars file in `/tmp` on every run, plus an
  empty root-owned "APT log" file per package batch that nothing wrote to.
- Tab-indented Alpine blocks in `install.sh` and `TLSCryptV2Verify.sh`
  reformatted with the project's `shfmt -i 2 -ci -sr -bn`, so the tree lints
  clean.

### 12. CI

Travis CI no longer runs for this project. `.github/workflows/lint.yml` runs
the same shellcheck and shfmt checks as `.travis.yml` on every push. The
semantic-release and install.pivpn.io Pages workflows now only run in
`pivpn/pivpn`, so the fork never tries to publish releases or a Pages site.

### 13. Installing from a local clone

Upstream's installer always clones its scripts from a fixed URL, even when you
start it from a clone (`git clone ... && bash pivpn/auto_install/install.sh`
still installs whatever `pivpnGitUrl` points at). That ties an install to one
git server and needs that server to be readable anonymously.

Now, run from a clone (the new top-level `./install.sh`, or
`auto_install/install.sh` inside a clone), the installer installs **that
clone's last commit** and contacts no git server, so the repository can live
on a private Gitea, or nowhere. Run on its own (downloaded or piped), it still
clones `pivpnGitUrl`; `--giturl`/`--gitbranch` and the new `PIVPN_GIT_URL`/
`PIVPN_GIT_BRANCH` variables override either way. [INSTALL.md](INSTALL.md)
describes both routes.

How it works and what it handles:

- The installed copy at `/usr/local/src/pivpn` is a root-owned shallow clone
  of your clone, whose origin is your clone. `pivpn update` therefore updates
  from it (`git pull` the clone first), using your clone's credentials, never
  root's.
- Your clone is owned by you but read by root, which git refuses as "dubious
  ownership". Command-line `-c safe.directory` doesn't reach the upload-pack
  side of a local clone (tested), so the exception for exactly that repository
  is passed to upload-pack and kept in `remote.origin.uploadpack` for later
  fetches. (Under `sudo`, git also accepts repositories owned by the invoking
  user; the exception covers a root shell and other owners too.)
- Uncommitted changes in the clone are listed with a warning, and an
  interactive run asks before continuing, since only the last commit is
  installed.
- Started from the installed copy itself, the installer reinstalls from that
  copy's origin instead of deleting the folder it is about to clone from.
- `pivpn update --url` accepts a clone's path as well as a git URL, to move an
  install between a clone and a server in either direction; a missing clone is
  reported with that hint.
- The uninstall and low-disk messages no longer name a GitHub URL.

### 14. `setupVars.conf` unreadable by the installing user (upstream `test` branch regression)

Upstream's unreleased mktemp change (`bad504d`) creates the temporary settings
file with mode 0600, and `cp` carried that mode to
`/etc/pivpn/<protocol>/setupVars.conf`. The installer runs as a normal user and
checks those files with `[[ -r ]]`, so when run again to add the second
protocol it no longer saw the first: `/usr/local/bin/pivpn` was linked to the
new protocol's script instead of the dual-protocol command, and an interactive
run skipped the Update/Repair/Reconfigure menu. Found while testing route 13 as
a normal user; the file is now installed with mode 0644 again (settings only,
no keys).

### 15. Setup menu and guided setups for the extras

The extras needed several manual steps each (copy files, edit a config file
with the tokens, enable units, and for Proton Drive download and verify the
CLI, create a GPG key and a `pass` store, sign in). Now:

- **`./install.sh` opens a setup menu** when run in a terminal without
  options: PiVPN, DuckDNS, Proton Drive and Tailscale, each with its current
  state (installed, failing, not set up). *PiVPN* runs the installer and
  returns to the menu; the menu offers the reboot when you leave it. With
  options (`--unattended`, `--no-menu`, ...) or without a terminal it goes
  straight to the installer, as before. After an interactive install that
  didn't start from the menu, the installer offers to open it.
- **Guided setups** (`extras/*/setup.sh`, whiptail, sized like the
  installer's dialogs, and fitting an 80x24 terminal) ask for the
  credentials and choices, check them on the spot (DuckDNS update, Gotify
  test message, Proton sign-in, Tailscale sign-in), show a summary before
  changing anything, and offer "Go back" when cancelled halfway. Run again,
  they start from the current settings.
- **Proton Drive:** the CLI is installed (or updated) from Proton's release
  list with its SHA-512 checked; sign-in shows Proton's approval link and a
  QR code; the remote folder can be picked in a browser of the Drive
  (including shared folders) or typed; an existing personal `pass` store is
  left alone.
- **Tailscale** (new extra): installs from `pkgs.tailscale.com`; exit node,
  subnet router (LAN prefilled), Tailscale SSH and tailnet DNS as checkboxes;
  sign-in with link/QR or auth key (passed through a root-only file); it
  then reports whether the routes are approved and whether key expiry is on.

Shared helpers are in `extras/lib/common.sh`. Tested by driving every dialog
in a pseudo-terminal (80x24 and 140x50) against stand-ins for `systemctl`,
`curl`, the Proton Drive CLI and `tailscale`, with the real `gpg`, `pass`,
`runuser`, sync script and DuckDNS updater; not yet on a real systemd boot.

---

## Extras

Optional add-ons in `extras/`, not used by the installer. Each has a guided
setup (`setup.sh` in its folder), reachable from the setup menu that
`./install.sh` opens (see 15):

- `extras/duckdns-update/`: a systemd timer that updates a DuckDNS name every 5
  minutes using DuckDNS's own IP detection, with optional Gotify alerts on an
  IP change, on failure and on recovery.
- `extras/proton-drive-sync/`: mirrors `~/ovpns` and `~/configs` to Proton
  Drive with the official CLI when PiVPN changes them; revoked clients' files
  go to the Proton trash.
- `extras/tailscale/`: installs Tailscale and joins the tailnet, optionally as
  exit node and/or subnet router, with IP forwarding and Tailscale's UDP
  setting for routers.

---

## Upstream `test` branch commits included

| Upstream | Change |
|---|---|
| `bad504d` | Temporary setup file created with `mktemp` (TOCTOU race); its side effect on file permissions is fixed by 14 |
| `389c1a6`, `21b9487` | Alpine detection cleanup; stray `\=` in grep patterns removed (avoids "stray \\" warnings with GNU grep 3.8+) |
| `92b281e` | Don't reset Pi-hole v6 `dns.listeningMode` if it already serves VPN clients |
| `416c68e` | Parse flags before the distribution check |
| `c2e5f73` | Detect containers instead of guessing from kernel modules (WireGuard) |
| `7612808` | WireGuard client configs include a custom MTU |
| `5ce09ed`, `73ec0b7` | EasyRSA extraction fix (issue A) and cleanup |

---

## Found but not changed

| Finding | Why left alone |
|---|---|
| `installOpenVPN` uses `apt-key` (removed in apt 3.x) for the OpenVPN repository | Only runs where the distro's OpenVPN is older than 2.5 (Ubuntu 20.04 era). Never reached on Debian 12/13 or Ubuntu 22.04+. |
| Linux clients log `Options error: Unrecognized option ... block-outside-dns` | Windows-only option pushed by the server; Linux ignores it and connects. Removing it would weaken Windows clients. |
| OpenVPN 2.7 logs `--persist-key option ignored` and `OpenSSL 3.0+ builds do not support ... --ecdh-curve` | Informational: 2.7 always persists keys and uses OpenSSL's default groups. Both options still matter on 2.6 (Ubuntu 24.04). |
| `iptables-save` stores every loaded rule in `/etc/iptables/rules.v4`, including other daemons' chains (e.g. Tailscale's `ts-*`) | Harmless with Tailscale's default iptables mode: `tailscaled` deletes and recreates its chains at start. Changing how PiVPN persists rules is a larger redesign. |
| EasyRSA is pinned to 3.2.3; 3.2.6/3.2.7 exist | PiVPN's command sequence behaves the same on 3.2.6 (tested), but no 3.2.4–3.2.7 change matters here, so the pin stays with upstream's tested version. |
| `pivpn` clients connect with `Note: --cipher is not set ...` in the log | Informational in 2.6/2.7 when `cipher` is absent, which is the intended state. |

---

## Corrections to the earlier write-ups

- `pivpn-openvpn-cipher-fix.md`, "PiVPN script updates are safe": upstream's
  `pivpn update` doesn't replace anything, it exits immediately (issue 8). In
  this fork it updates the git checkout; generated files are still untouched,
  so that note's conclusion holds.
- `pivpn-openvpn-cipher-fix.md` recommends `pivpn ovpn add -o`: on upstream that
  changes the client's IP and key (issue 3). Safe in this fork.
- `pivpn-openvpn-cipher-fix.md`, CBC fallback: on OpenVPN 2.6/2.7 any
  non-AEAD cipher in the server's `data-ciphers` disables kernel offload (DCO).
  Remove `:AES-256-CBC` once old profiles are replaced, as it suggests.
- `pivpn-easyrsa-tar-fix.md`, open item 7 ("later updates will hit the same
  bug until upstream fixes it"): fixed in this fork and on upstream's `test`
  branch.

---

## How this was tested

In an Ubuntu 24.04 container (OpenVPN 2.6.19, GNU tar 1.35, EasyRSA 3.2.3):

- The fork's installer ran unattended end to end for OpenVPN (ECC,
  tls-crypt-v2, TLS 1.3) and then again to add WireGuard (dual protocol),
  both as root and as a normal user with sudo; both NAT rules were installed
  and saved, and the dual `pivpn` command was linked.
- Installing from a clone (13): a clone owned by a normal user installed via
  `./install.sh` (OpenVPN, then WireGuard), with the uncommitted-changes
  warning shown; `pivpn update` picked up a new commit from the clone; the
  installer restarted from the installed copy reinstalled from the clone;
  `pivpn update --url` switched to the GitHub URL and back; a missing clone was
  reported. The launch contexts were checked separately: clone (absolute and
  relative path, through a symlink, through `./install.sh`) installs locally;
  a downloaded copy, a piped run and a tarball without `.git` use
  `pivpnGitUrl`, and a piped run cloned from GitHub.
- A real OpenVPN server ran from the generated `server.conf` (dropping to the
  `openvpn` user, with the tls-crypt-v2 verify script), and clients connected
  from a separate network namespace:

  | Client | OpenVPN 2.6 server | OpenVPN 2.7 server |
  |---|---|---|
  | New profile, `openvpn` CLI | AES-256-GCM | AES-256-GCM |
  | New profile, NetworkManager-style `--data-ciphers` | AES-256-GCM | AES-256-GCM |
  | Old `cipher AES-256-CBC` profile, CLI | AES-256-GCM (deprecation warning) | not tested |
  | Old profile, NetworkManager-style (`--data-ciphers AES-256-CBC`) | rejected: no shared cipher (expected, see B) | not tested |
  | Profile with `cipher AES-256-GCM` (what traditional mode now writes), CLI and NetworkManager-style | AES-256-GCM, no warning | not tested |
  | Revoked client | rejected (tls-crypt-v2 metadata removed) | rejected |

- Revoke, regenerate (`-o`), `pivpn -d` CRL repair and `pivpn update`
  (same branch, other branch, discarding local edits) were run against that
  install.
- Ubuntu 26.04 pieces were checked against packages from the resolute archive:
  OpenVPN 2.7.0 (run against the same server config), sudo-rs 0.2.13 (`-E`
  behaviour), uutils coreutils 0.10.0 (each command the scripts use).
- shellcheck and shfmt (both Ubuntu 24.04's packaged versions and current
  releases) pass on the whole tree.

**Not tested:** a real systemd boot (the container has no systemd, so service
start/enable paths and reboot persistence weren't exercised), WireGuard
traffic (no kernel module in the container), real NetworkManager and phone
clients, Debian, Raspberry Pi OS and Alpine.

---

## Keeping the fork current

```bash
git remote add upstream https://github.com/pivpn/pivpn.git   # once
git fetch upstream
git merge upstream/master        # or cherry-pick from upstream/test
git push origin master           # origin = GitHub, Gitea, wherever the fork lives
```

Then on the server: `git pull` in the clone PiVPN was installed from, and
`pivpn update` (just `pivpn update` for a standalone install).
