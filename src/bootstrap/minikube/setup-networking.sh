#!/usr/bin/env bash
set -euo pipefail

echo "🌐  Adjusting Minikube/libvirt networking (requires sudo privileges)"

# Ensure forwarding is enabled
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Discover all libvirt bridge interfaces (virbr*) and their IP addresses.
# For each bridge, derive the corresponding /24 subnet (e.g. 192.168.39.1/24 → 192.168.39.0/24)
# which is later used when creating NAT rules for Minikube/libvirt networking.
ip -br addr | awk '$1 ~ /^virbr/ {print $1,$3}' | while read -r br ip; do
    subnet=$(awk -F'[./]' '{print $1"."$2"."$3".0/24"}' <<< "$ip")

    echo "🔧 [$br] Ensuring NAT and forwarding rules ($subnet)"

    # Ensure outbound traffic from the libvirt subnet is NATed (masqueraded) when leaving the host.
    # This allows VMs on the bridge network (e.g. Minikube nodes) to reach external networks like the internet.
    # First check if the rule already exists (-C); if not, append it (-A).
    sudo iptables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE

    # Allow packets coming *from* the libvirt bridge interface to be forwarded.
    # This enables traffic originating from VMs/Minikube nodes to pass through the host.
    # Only insert the rule if it does not already exist.
    sudo iptables -C FORWARD -i "$br" -j ACCEPT 2>/dev/null || \
    sudo iptables -I FORWARD -i "$br" -j ACCEPT

    # Allow packets being forwarded *to* the libvirt bridge interface.
    # This ensures return traffic and inter-network routing back to the VMs works correctly.
    # Again, check first to avoid adding duplicate rules.
    sudo iptables -C FORWARD -o "$br" -j ACCEPT 2>/dev/null || \
    sudo iptables -I FORWARD -o "$br" -j ACCEPT
done

echo "Networking rules applied."
