#!/bin/bash
# Install PiVPN from this clone of the repository.
#
#   git clone <your PiVPN repository> pivpn && cd pivpn && ./install.sh
#
# Run in a terminal without options, this opens the setup menu: PiVPN itself
# and the extras (DuckDNS, Proton Drive sync, Tailscale). With options it
# goes straight to the PiVPN installer, and every installer option works, e.g.
#   ./install.sh --unattended ~/pivpn-wireguard.conf
#   ./install.sh --no-menu        (the interactive installer, without the menu)
# See INSTALL.md for both ways to install (from a clone, or on its own).

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

if [[ "$#" -eq 0 ]] && [[ -t 0 && -t 1 ]] && [[ -f "${dir}/extras/setup.sh" ]]; then
  exec bash "${dir}/extras/setup.sh"
fi

args=()

for arg in "$@"; do
  [[ "${arg}" == "--no-menu" ]] || args+=("${arg}")
done

exec bash "${dir}/auto_install/install.sh" "${args[@]}"
