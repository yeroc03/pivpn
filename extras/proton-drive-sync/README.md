# Proton Drive sync for PiVPN client profiles

Mirrors the client profiles PiVPN writes for its install user to Proton Drive,
so they can be downloaded from anywhere:

| Local folder | Contents | Remote folder |
|---|---|---|
| `~/ovpns` | OpenVPN `.ovpn` profiles | `<remote>/ovpns` |
| `~/configs` | WireGuard `.conf` profiles | `<remote>/configs` |

`<remote>` defaults to `/my-files/PiVPN/<short hostname>`.

- **When:** a systemd path unit starts a sync whenever either folder changes
  (`pivpn add`, `pivpn revoke`/`remove`), and a daily timer catches anything
  missed. The daily run also keeps the Proton session in regular use.
- **What:** new and changed files are uploaded (unchanged ones are skipped by
  the CLI). Remote profiles whose local file is gone are moved to the Proton
  Drive **trash**, so a revoked client's private key does not linger in the
  folder. Set `PIVPN_SYNC_PRUNE=0` to never remove anything.
- **How:** the official [Proton Drive CLI](https://proton.me/support/drive-cli)
  (`proton-drive`), signed in once as the PiVPN install user, with the session
  kept in that user's GPG-encrypted [`pass`](https://www.passwordstore.org/)
  store so it works without a desktop keyring.

These profiles contain private keys. Proton Drive is end-to-end encrypted,
but anyone who can sign in to that Proton account can use your VPN, so keep
two-factor authentication on it (see the blueprint for a least-privilege
setup with a separate Proton account).

## Files

| File | Install to |
|---|---|
| `pivpn-proton-sync` | `/usr/local/bin/pivpn-proton-sync` (mode 755) |
| `pivpn-proton-sync@.service` | `/etc/systemd/system/` |
| `pivpn-proton-sync@.path` | `/etc/systemd/system/` |
| `pivpn-proton-sync@.timer` | `/etc/systemd/system/` |
| `pivpn-proton-sync.default` | `/etc/default/pivpn-proton-sync` (optional) |

The units are templates: the instance name is the PiVPN install user, and
they assume its home is `/home/<user>`.

## Setup (as root, with `USER_=` your PiVPN install user)

```bash
USER_=yeroc03
apt install -y pass gnupg jq

# 1. The CLI (download the Linux x64 build from
#    https://proton.me/download/drive/cli/index.html and check its SHA-512)
install -m 755 proton-drive /usr/local/bin/proton-drive

# 2. A passphrase-less GPG key and pass store for that user, for unattended use
runuser -u "$USER_" -- gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-gen-key "pivpn-proton-sync <pivpn-proton-sync@localhost>" default default never
runuser -u "$USER_" -- pass init pivpn-proton-sync@localhost

# 3. Sign in once (open the printed URL on any device and approve)
runuser -u "$USER_" -- env PROTON_DRIVE_CREDENTIALS_STORE=pass proton-drive auth login

# 4. Script and units
SRC=/usr/local/src/pivpn/extras/proton-drive-sync
install -m 755 "$SRC/pivpn-proton-sync" /usr/local/bin/
install -m 644 "$SRC"/pivpn-proton-sync@.{service,path,timer} /etc/systemd/system/
install -m 644 "$SRC/pivpn-proton-sync.default" /etc/default/pivpn-proton-sync
runuser -u "$USER_" -- mkdir -p "/home/$USER_/ovpns" "/home/$USER_/configs"
systemctl daemon-reload
systemctl enable --now "pivpn-proton-sync@$USER_.path" "pivpn-proton-sync@$USER_.timer"

# 5. First sync, and its log
systemctl start "pivpn-proton-sync@$USER_.service"
journalctl -u "pivpn-proton-sync@$USER_.service" -n 20
```

If the log says `not signed in to Proton Drive`, repeat step 3.

## Settings

`/etc/default/pivpn-proton-sync` (or the environment when run by hand):

| Variable | Default | Meaning |
|---|---|---|
| `PIVPN_SYNC_REMOTE` | `/my-files/PiVPN/<host>` | Remote parent folder |
| `PIVPN_SYNC_DIRS` | `~/ovpns ~/configs` | Local folders to mirror |
| `PIVPN_SYNC_PRUNE` | `1` | Trash remote files with no local copy |
| `PROTON_DRIVE_BIN` | `proton-drive` | CLI to run |
| `PROTON_DRIVE_CREDENTIALS_STORE` | `pass` (set in the unit) | CLI session store |

To upload into a folder another Proton account shared with you, set
`PIVPN_SYNC_REMOTE` to its `/shared-with-me/...` path.
