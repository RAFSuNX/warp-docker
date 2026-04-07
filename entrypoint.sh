#!/bin/bash

# exit when any command fails
set -e

WARP_DNS_CHECK_HOST="${WARP_DNS_CHECK_HOST:-cloudflareclient.com}"
WARP_DNS_WAIT_TIMEOUT="${WARP_DNS_WAIT_TIMEOUT:-120}"
WARP_SVC_WAIT_TIMEOUT="${WARP_SVC_WAIT_TIMEOUT:-120}"
WARP_CONNECT_RETRIES="${WARP_CONNECT_RETRIES:-5}"
WARP_PROTOCOL_SET_MAX_RETRIES="${WARP_PROTOCOL_SET_MAX_RETRIES:-30}"

# create a tun device if not exist
# allow passing device to ensure compatibility with Podman
if [ ! -e /dev/net/tun ]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    sudo chmod 600 /dev/net/tun
fi

# set required sysctls inside the container (avoids needing sysctl in pod spec / compose)
sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1 2>/dev/null || true

# IPv6 handling - disable if FORCE_IPV4 is set
if [ -n "$FORCE_IPV4" ]; then
    echo "[ipv4] Disabling IPv6 and forcing IPv4 preference..."
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
    # Set IPv4 preference for DNS resolution
    echo "precedence ::ffff:0:0/96 100" | sudo tee /etc/gai.conf >/dev/null
else
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
fi

# ensure eth0 MTU is large enough for WARP WireGuard (needs >= 1340)
# Flannel-over-Tailscale can set eth0 to 1230 which is too small
sudo ip link set eth0 mtu 1400 2>/dev/null || true

# start dbus
sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
    sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf --fork
fi

# start the daemon
sudo warp-svc --accept-tos &

# wait for the daemon to start
sleep "$WARP_SLEEP"

# wait for DNS to be resolvable (k3s CoreDNS may not be ready immediately)
echo "Waiting for DNS readiness (${WARP_DNS_CHECK_HOST})..."
dns_elapsed=0
while ! getent hosts "$WARP_DNS_CHECK_HOST" >/dev/null 2>&1; do
    if [ "$dns_elapsed" -ge "$WARP_DNS_WAIT_TIMEOUT" ]; then
        echo "ERROR: DNS was not ready after ${WARP_DNS_WAIT_TIMEOUT}s"
        exit 1
    fi
    echo "  DNS not ready yet, retrying in 2s..."
    sleep 2
    dns_elapsed=$((dns_elapsed + 2))
done
echo "DNS is ready"

# wait for warp-svc to respond to IPC
echo "Waiting for warp-svc..."
svc_elapsed=0
while ! warp-cli status >/dev/null 2>&1; do
    if [ "$svc_elapsed" -ge "$WARP_SVC_WAIT_TIMEOUT" ]; then
        echo "ERROR: warp-svc was not ready after ${WARP_SVC_WAIT_TIMEOUT}s"
        exit 1
    fi
    sleep 1
    svc_elapsed=$((svc_elapsed + 1))
done
echo "warp-svc is ready"

# if /var/lib/cloudflare-warp/reg.json not exists, setup new warp client
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    # if /var/lib/cloudflare-warp/mdm.xml not exists or REGISTER_WHEN_MDM_EXISTS not empty, register the warp client
    if [ ! -f /var/lib/cloudflare-warp/mdm.xml ] || [ -n "$REGISTER_WHEN_MDM_EXISTS" ]; then
        echo "Registering WARP client..."
        warp-cli registration new
        # registration is async — daemon processes it in the background
        echo "Waiting for registration to finalize..."
        for i in $(seq 1 15); do
            warp-cli status 2>&1 | grep -v "Registration Missing" && break || sleep 2
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
    protocol_set_ok=0
    for i in $(seq 1 "$WARP_PROTOCOL_SET_MAX_RETRIES"); do
        if warp-cli tunnel protocol set "$WARP_PROTOCOL" >/dev/null 2>&1; then
            protocol_set_ok=1
            break
        fi
        echo "  Protocol set failed (registration may still be finalizing), retrying in 2s..."
        sleep 2
    done
    if [ "$protocol_set_ok" -ne 1 ]; then
        echo "ERROR: failed to set tunnel protocol after ${WARP_PROTOCOL_SET_MAX_RETRIES} attempts"
        exit 1
    fi
fi

# set up kill switch before connecting (blocks non-VPN traffic via nftables)
if [ -n "$WARP_KILL_SWITCH" ]; then
    echo "[kill-switch] Setting up kill switch..."
    KILL_SWITCH_STRICT="${WARP_KILL_SWITCH_STRICT:-}"

    if [ -z "$KILL_SWITCH_STRICT" ]; then
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
    else
        echo "[kill-switch] Strict mode enabled: local eth0/container-network bypasses are disabled."
    fi

    sudo nft add table inet kill_switch

    # output chain: traffic originating from this container
    sudo nft add chain inet kill_switch output { type filter hook output priority 0 \; policy drop \; }
    sudo nft add rule inet kill_switch output oifname "lo" accept
    sudo nft add rule inet kill_switch output oifname "CloudflareWARP" accept
    # allow warp-svc (root) to reach Cloudflare servers for tunnel establishment
    sudo nft add rule inet kill_switch output meta skuid 0 accept
    if [ -z "$KILL_SWITCH_STRICT" ]; then
        for net in $LOCAL_NETS; do
            sudo nft add rule inet kill_switch output ip daddr "$net" accept
        done
        for net6 in $LOCAL_NETS6; do
            sudo nft add rule inet kill_switch output ip6 daddr "$net6" accept
        done
        # allow IPv6 link-local (NDP, router discovery)
        sudo nft add rule inet kill_switch output ip6 daddr fe80::/10 accept
    fi

    # forward chain: traffic routed through this container (NAT gateway / sidecar mode)
    sudo nft add chain inet kill_switch forward { type filter hook forward priority 0 \; policy drop \; }
    sudo nft add rule inet kill_switch forward oifname "CloudflareWARP" accept
    sudo nft add rule inet kill_switch forward ct state established,related accept
    if [ -z "$KILL_SWITCH_STRICT" ]; then
        for net in $LOCAL_NETS; do
            sudo nft add rule inet kill_switch forward ip daddr "$net" accept
        done
        for net6 in $LOCAL_NETS6; do
            sudo nft add rule inet kill_switch forward ip6 daddr "$net6" accept
        done
        sudo nft add rule inet kill_switch forward ip6 daddr fe80::/10 accept
    fi

    # K3S/Kubernetes support: add service CIDR to allowed networks
    # Default k3s service CIDR is 10.43.0.0/16
    K3S_SERVICE_CIDR="${K3S_SERVICE_CIDR:-}"
    if [ -n "$K3S_SERVICE_CIDR" ]; then
        if [ -n "$KILL_SWITCH_STRICT" ]; then
            echo "[kill-switch] Adding k3s service CIDR for root-only WARP processes: $K3S_SERVICE_CIDR"
            sudo nft add rule inet kill_switch output meta skuid 0 ip daddr "$K3S_SERVICE_CIDR" accept
        else
            echo "[kill-switch] Adding k3s service CIDR: $K3S_SERVICE_CIDR"
            sudo nft add rule inet kill_switch output ip daddr "$K3S_SERVICE_CIDR" accept
        fi
        sudo nft add rule inet kill_switch forward ip daddr "$K3S_SERVICE_CIDR" accept
    fi

    # Additional custom CIDRs (comma-separated)
    if [ -n "$KILL_SWITCH_ALLOW_CIDRS" ]; then
        echo "[kill-switch] Adding custom allowed CIDRs..."
        IFS=',' read -ra CIDRS <<< "$KILL_SWITCH_ALLOW_CIDRS"
        for cidr in "${CIDRS[@]}"; do
            cidr=$(echo "$cidr" | tr -d ' ')
            if [ -n "$cidr" ]; then
                echo "  Adding: $cidr"
                if echo "$cidr" | grep -q ":"; then
                    sudo nft add rule inet kill_switch output ip6 daddr "$cidr" accept 2>/dev/null || true
                    sudo nft add rule inet kill_switch forward ip6 daddr "$cidr" accept 2>/dev/null || true
                else
                    sudo nft add rule inet kill_switch output ip daddr "$cidr" accept 2>/dev/null || true
                    sudo nft add rule inet kill_switch forward ip daddr "$cidr" accept 2>/dev/null || true
                fi
            fi
        done
    fi

    echo "[kill-switch] Kill switch active. Non-VPN traffic blocked."
fi

# connect to WARP
echo "Connecting to WARP..."
connected=0
for i in $(seq 1 "$WARP_CONNECT_RETRIES"); do
    if warp-cli --accept-tos connect >/dev/null 2>&1; then
        connected=1
        break
    fi
    echo "  Connect attempt $i/$WARP_CONNECT_RETRIES failed, retrying in 2s..."
    sleep 2
done
if [ "$connected" -ne 1 ]; then
    echo "ERROR: failed to connect to WARP after ${WARP_CONNECT_RETRIES} attempts"
    exit 1
fi

# wait for connection to stabilize
sleep "$WARP_SLEEP"

# Clear IP exclusions if requested (useful for private trackers that WARP auto-excludes)
if [ -n "$WARP_CLEAR_EXCLUSIONS" ]; then
    echo "[exclusions] Clearing custom IP exclusions..."
    warp-cli tunnel ip reset 2>/dev/null || true
    echo "[exclusions] IP exclusions cleared"
fi

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

    # Only add IPv6 NAT if not forcing IPv4
    if [ -z "$FORCE_IPV4" ]; then
        sudo nft add table ip6 nat
        sudo nft add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 \; }
        sudo nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade
        sudo nft add table ip6 mangle
        sudo nft add chain ip6 mangle forward { type filter hook forward priority mangle \; }
        sudo nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
    fi

    echo "[NAT] NAT enabled"
fi

# start watchdog if enabled
if [ -n "$WARP_WATCHDOG" ]; then
    /watchdog.sh &
    echo "[watchdog] Connection watchdog started (interval: ${WARP_WATCHDOG_INTERVAL:-30}s)"
fi

# Print connection info
echo ""
echo "========================================="
echo "WARP Docker Ready!"
echo "========================================="
warp-cli status 2>/dev/null || true
echo ""
if [ -n "$WARP_ENABLE_NAT" ]; then
    echo "NAT Mode: Enabled"
fi
if [ -n "$WARP_KILL_SWITCH" ]; then
    echo "Kill Switch: Active"
fi
if [ -n "$FORCE_IPV4" ]; then
    echo "IPv4 Only: Yes"
fi
echo "SOCKS5/HTTP Proxy: 0.0.0.0:1080"
echo "========================================="
echo ""

# start the proxy
gost $GOST_ARGS
