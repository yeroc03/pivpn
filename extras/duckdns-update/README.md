# DuckDNS updater

Keeps a DuckDNS name (the one in your PiVPN client profiles) pointing at your
home's public IPv4 address, and optionally tells Gotify when that address
changes or when updates start or stop failing.

- **How:** a systemd timer runs `duckdns-update` every 5 minutes. It calls
  DuckDNS's update URL with the IP left blank, so DuckDNS records the address
  the request came from. That is DuckDNS's own recommended method; no "what is
  my IP" service is involved, and no package needs installing beyond `curl`.
- **Where:** on the PiVPN machine itself, so the record is updated whenever the
  VPN is up.
- **Alerts (optional):** one Gotify message when the IP changes, one when
  updates start failing (not one every 5 minutes), and one when they work
  again. Each run is also logged to the journal.
- **Security:** runs as a throwaway unprivileged user (systemd
  `DynamicUser`); the tokens live in a root-only config file and are passed to
  `curl` on stdin, so they never appear in `ps`.

Not installed by the PiVPN installer.

## Files

| File | Install to |
|---|---|
| `duckdns-update` | `/usr/local/bin/duckdns-update` (mode 755) |
| `duckdns-update.service` | `/etc/systemd/system/` |
| `duckdns-update.timer` | `/etc/systemd/system/` |
| `duckdns-update.conf` | `/etc/duckdns-update.conf` (mode 600, root) |

## Setup

From the top folder of your PiVPN clone:

```bash
cd extras/duckdns-update
sudo install -m 755 duckdns-update /usr/local/bin/
sudo install -m 644 duckdns-update.service duckdns-update.timer /etc/systemd/system/
sudo install -m 600 duckdns-update.conf /etc/duckdns-update.conf
sudo nano /etc/duckdns-update.conf      # subdomain, token, optional Gotify URL and app token
sudo systemctl daemon-reload
sudo systemctl enable --now duckdns-update.timer
sudo systemctl start duckdns-update.service
journalctl -u duckdns-update -n 5
```

A run where nothing changed logs nothing; a change logs
`<name>.duckdns.org now points to <ip>`. Check the result with
`dig +short <name>.duckdns.org`, which should match
`curl -4 -s https://ifconfig.me`.

- **Gotify:** in Gotify, *Apps → Create Application*, then put its token in
  `GOTIFY_TOKEN` and your server in `GOTIFY_URL`. Use a URL the machine can
  reach and whose TLS certificate it trusts.
- **Replacing another updater:** if inadyn or ddclient already updates this
  name, stop it (`sudo systemctl disable --now inadyn`) so only one runs.
- **IPv6:** this keeps the IPv4 record only. On duckdns.org, leave the IPv6
  field of the name empty; a stale IPv6 address there sends IPv6-capable
  devices to a dead end.
- **Interval:** `OnUnitActiveSec=5min` in the timer (about 105,000 checks a
  year, each a tiny request). A longer interval means fewer requests but a
  longer wait after your IP changes.

## What an IP change means for VPN clients

- **OpenVPN** clients follow by themselves: when the old address stops
  answering they reconnect (within about 2 minutes with PiVPN's settings) and
  look the name up again.
- **WireGuard** clients look the name up only when the tunnel starts. A device
  that is connected when the IP changes keeps using the old address until the
  tunnel is turned off and on, which the Gotify alert reminds you of.
- **Tailscale** does not use DuckDNS at all and keeps working.

## Settings

`/etc/duckdns-update.conf`, read by the service:

| Variable | Required | Meaning |
|---|---|---|
| `DUCKDNS_DOMAINS` | yes | Subdomain(s) without `.duckdns.org`, comma separated |
| `DUCKDNS_TOKEN` | yes | Your DuckDNS token (top of duckdns.org after signing in) |
| `GOTIFY_URL` | no | Gotify server, e.g. `https://gotify.example.lan` |
| `GOTIFY_TOKEN` | no | Gotify application token |

The script exits 1 when an update fails (so `systemctl --failed` shows it)
and 2 when the required settings are missing. It remembers the last result in
`/var/lib/duckdns-update/state`.
