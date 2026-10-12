#!/bin/bash
# Install PiVPN from this clone of the repository.
#
#   git clone <your PiVPN repository> pivpn && cd pivpn && ./install.sh
#
# Every installer option works here too, e.g.
#   ./install.sh --unattended ~/pivpn-wireguard.conf
# See INSTALL.md for both ways to install (from a clone, or on its own).

exec bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/auto_install/install.sh" "$@"
