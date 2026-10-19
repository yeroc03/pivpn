# Tailscale on the PiVPN machine

Joins the PiVPN machine to your [Tailscale](https://tailscale.com) tailnet,
optionally as:

- an **exit node**: your devices send their internet traffic through your home
  connection, like PiVPN's full-tunnel profiles;
- a **subnet router**: your devices reach the LAN (NAS, Proxmox, printers)
  over Tailscale without installing Tailscale on each LAN device.

Tailscale needs no port forwarding and works next to PiVPN's WireGuard and
OpenVPN. Not installed by the PiVPN installer.

## Guided setup

```bash
./install.sh                 # in your PiVPN clone: the setup menu, then "Tailscale"
extras/tailscale/setup.sh    # or this one directly (uses sudo itself)
```

It walks through:

1. **Roles**, as checkboxes: exit node, subnet router, Tailscale SSH, and
   whether to use the tailnet's DNS (off by default, so the machine keeps
   using your own DNS server such as AdGuard Home).
2. **Subnet routes**, prefilled with the LAN the machine is on (PiVPN's
   interface if PiVPN is installed). Addresses are normalized
   (`192.168.11.5/24` becomes `192.168.11.0/24`); IPv6 routes are accepted.
3. **Sign-in**, if the machine isn't signed in yet: a link and QR code you
   open on any device, or an auth key (admin console, *Settings*, *Keys*).
   The key is handed to Tailscale through a temporary root-only file, never
   on a command line.
4. A summary, then it applies everything:
   - installs Tailscale from its official repository
     (`pkgs.tailscale.com`, Ubuntu / Debian / Raspberry Pi OS), if missing;
   - for an exit node or subnet router: IP forwarding in
     `/etc/sysctl.d/99-tailscale.conf`, and Tailscale's
     [recommended UDP GRO setting](https://tailscale.com/kb/1320/performance-best-practices)
     on the LAN interface, kept across reboots (`networkd-dispatcher` where
     systemd-networkd runs, otherwise `tailscale-udp-gro.service`);
   - `tailscale up` when signing in, `tailscale set` when the machine is
     already signed in (so other settings you made are kept).
5. The result: the machine's tailnet address, and whether the exit node and
   each route are approved yet.

Run it again to change the roles; the current settings are preselected.

## After the setup

- **Approve** new routes and the exit node once, in the
  [admin console](https://login.tailscale.com/admin/machines): the machine's
  `...` menu, *Edit route settings*. (Auto-approvers in your tailnet policy
  can do this for you.) A route also shows as waiting while another subnet
  router advertising the same network is the primary one: Tailscale keeps
  such routers as a failover pair.
- **Disable key expiry** for the machine in the same menu, or it drops off
  the tailnet when its key expires (180 days by default).
- **Linux clients** use subnet routes after `sudo tailscale set --accept-routes`;
  phones and Windows/macOS clients use them automatically. To use the exit
  node, pick it in the client (`sudo tailscale set --exit-node=<machine>` on
  Linux).
- **Direct connections:** optionally forward UDP 41641 on your router to
  this machine; without it Tailscale still works, sometimes through relays.

## Notes

- Install PiVPN first: PiVPN saves the firewall rules it finds into
  `/etc/iptables/rules.v4`, and it's tidier when Tailscale's chains aren't
  among them (they're harmless if they are; `tailscaled` recreates them).
- `tailscale up` and `tailscale set` are given `--accept-risk=lose-ssh`, so
  turning Tailscale SSH off doesn't stop for a confirmation prompt. If you are
  connected through Tailscale SSH at the time, that session ends.
