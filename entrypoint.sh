#!/bin/bash

# exit when any command fails
set -e

# create a tun device if not exist
# allow passing device to ensure compatibility with Podman
if [ ! -e /dev/net/tun ]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    sudo chmod 600 /dev/net/tun
fi

# set required sysctls inside the container (avoids needing sysctl in pod spec / compose)
sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1 2>/dev/null || true
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true

# start dbus
sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# start the daemon
sudo warp-svc --accept-tos &

# wait for the daemon to start
sleep "$WARP_SLEEP"

# wait for DNS to be resolvable (k3s CoreDNS may not be ready immediately)
echo "Waiting for DNS readiness..."
while ! nslookup cloudflareclient.com >/dev/null 2>&1; do
    echo "  DNS not ready yet, retrying in 2s..."
    sleep 2
done
echo "DNS is ready"

# wait for warp-svc to respond to IPC
echo "Waiting for warp-svc..."
while ! warp-cli status >/dev/null 2>&1; do
    sleep 1
done
echo "warp-svc is ready"

# if /var/lib/cloudflare-warp/reg.json not exists, setup new warp client
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    # if /var/lib/cloudflare-warp/mdm.xml not exists or REGISTER_WHEN_MDM_EXISTS not empty, register the warp client
    if [ ! -f /var/lib/cloudflare-warp/mdm.xml ] || [ -n "$REGISTER_WHEN_MDM_EXISTS" ]; then
        echo "Registering WARP client..."
        warp-cli registration new
        # registration is async — wait for daemon to finalize it
        echo "Waiting for registration to finalize..."
        while ! warp-cli registration show >/dev/null 2>&1; do
            sleep 1
        done
        echo "Warp client registered!"
        # if a license key is provided, register the license
        if [ -n "$WARP_LICENSE_KEY" ]; then
            echo "License key found, registering license..."
            warp-cli registration license "$WARP_LICENSE_KEY" && echo "Warp license registered!"
        fi
    fi
else
    echo "Warp client already registered, skip registration"
fi

# set tunnel protocol if specified (e.g., "WireGuard" to avoid MASQUE issues on Oracle Cloud)
# accepted values: WireGuard, MASQUE (case-insensitive)
if [ -n "$WARP_PROTOCOL" ]; then
    # normalize common casings to what warp-cli expects
    case "$(echo "$WARP_PROTOCOL" | tr '[:upper:]' '[:lower:]')" in
        wireguard) WARP_PROTOCOL="WireGuard" ;;
        masque)    WARP_PROTOCOL="MASQUE" ;;
    esac
    echo "Setting tunnel protocol to ${WARP_PROTOCOL}..."
    # disconnect first in case daemon auto-connected with wrong protocol
    warp-cli --accept-tos disconnect 2>/dev/null || true
    sleep 1
    # retry protocol set in case registration is still finalizing
    while ! warp-cli tunnel protocol set "$WARP_PROTOCOL" 2>&1; do
        echo "  Protocol set failed (registration may still be finalizing), retrying in 2s..."
        sleep 2
    done
fi

# set up kill switch before connecting (blocks non-VPN traffic via nftables)
if [ -n "$WARP_KILL_SWITCH" ]; then
    echo "[kill-switch] Setting up kill switch..."

    # detect local/container networks to whitelist
    LOCAL_NETS=$(ip --json address | jq -r '
        .[] |
        select((.ifname != "lo") and (.ifname != "CloudflareWARP")) |
        .addr_info[] |
        select(.family == "inet") |
        "\(.local)/\(.prefixlen)"' | while read -r cidr; do
            if echo "$cidr" | grep -q "/32$"; then
                echo "$cidr"
            else
                ipcalc -n "$cidr" | grep Network | awk '{print $2}'
            fi
        done)

    LOCAL_NETS6=$(ip --json address | jq -r '
        .[] |
        select((.ifname != "lo") and (.ifname != "CloudflareWARP")) |
        .addr_info[] |
        select(.family == "inet6" and (.scope != "link")) |
        "\(.local)/\(.prefixlen)"')

    sudo nft add table inet kill_switch

    # output chain: traffic originating from this container
    sudo nft add chain inet kill_switch output { type filter hook output priority 0 \; policy drop \; }
    sudo nft add rule inet kill_switch output oifname "lo" accept
    sudo nft add rule inet kill_switch output oifname "CloudflareWARP" accept
    # allow warp-svc (root) to reach Cloudflare servers for tunnel establishment
    sudo nft add rule inet kill_switch output meta skuid 0 accept
    for net in $LOCAL_NETS; do
        sudo nft add rule inet kill_switch output ip daddr "$net" accept
    done
    for net6 in $LOCAL_NETS6; do
        sudo nft add rule inet kill_switch output ip6 daddr "$net6" accept
    done
    # allow IPv6 link-local (NDP, router discovery)
    sudo nft add rule inet kill_switch output ip6 daddr fe80::/10 accept

    # forward chain: traffic routed through this container (NAT gateway / sidecar mode)
    sudo nft add chain inet kill_switch forward { type filter hook forward priority 0 \; policy drop \; }
    sudo nft add rule inet kill_switch forward oifname "CloudflareWARP" accept
    sudo nft add rule inet kill_switch forward ct state established,related accept
    for net in $LOCAL_NETS; do
        sudo nft add rule inet kill_switch forward ip daddr "$net" accept
    done
    for net6 in $LOCAL_NETS6; do
        sudo nft add rule inet kill_switch forward ip6 daddr "$net6" accept
    done
    sudo nft add rule inet kill_switch forward ip6 daddr fe80::/10 accept

    echo "[kill-switch] Kill switch active. Non-VPN traffic blocked."
fi

# connect to WARP
echo "Connecting to WARP..."
warp-cli --accept-tos connect

# wait for connection to stabilize
sleep "$WARP_SLEEP"

# disable qlog if DEBUG_ENABLE_QLOG is empty
if [ -z "$DEBUG_ENABLE_QLOG" ]; then
    warp-cli --accept-tos debug qlog disable
else
    warp-cli --accept-tos debug qlog enable
fi

# if WARP_ENABLE_NAT is provided, enable NAT and forwarding
if [ -n "$WARP_ENABLE_NAT" ]; then
    # switch to warp mode
    echo "[NAT] Switching to warp mode..."
    warp-cli --accept-tos mode warp
    warp-cli --accept-tos connect

    # wait another seconds for the daemon to reconfigure
    sleep "$WARP_SLEEP"

    # enable NAT
    echo "[NAT] Enabling NAT..."
    sudo nft add table ip nat
    sudo nft add chain ip nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip mangle
    sudo nft add chain ip mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu

    sudo nft add table ip6 nat
    sudo nft add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip6 mangle
    sudo nft add chain ip6 mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
fi

# start watchdog if enabled
if [ -n "$WARP_WATCHDOG" ]; then
    /watchdog.sh &
    echo "[watchdog] Connection watchdog started (interval: ${WARP_WATCHDOG_INTERVAL:-30}s)"
fi

# start the proxy
gost $GOST_ARGS
