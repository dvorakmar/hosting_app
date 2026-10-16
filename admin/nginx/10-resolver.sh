#!/bin/sh
# ==============================================================================
# Automatická detekce DNS Resolveru pro Docker i Podman
# ==============================================================================
# Docker používá 127.0.0.11, Podman používá IP brány sítě (např. 10.89.0.1).
# Tento skript při startu Nginxu zjistí reálný nameserver z /etc/resolv.conf.
# ==============================================================================

DNS_IP=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)

if [ -z "$DNS_IP" ]; then
    DNS_IP="127.0.0.11"
fi

echo "resolver ${DNS_IP} valid=10s ipv6=off;" > /etc/nginx/conf.d/resolver.conf
echo "[Entrypoint] Nastaven DNS resolver pro Nginx: ${DNS_IP}"

