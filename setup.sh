#!/usr/bin/env bash
set -euo pipefail

install_mqtt() {
  install -m 755 "$(dirname "$0")/rwmqtt" /usr/local/bin/rwmqtt

  apt-get update -qq
  # fix error where python3-venv not installed by default
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv
  python3 -m venv /opt/roadwarrior-mqtt
  /opt/roadwarrior-mqtt/bin/pip install --quiet paho-mqtt vici geoip2

  if ! id roadwarrior &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin roadwarrior
  fi

  # roadwarrior.conf perms 600 by default. roadwarrior user (for daemon) needs read access
  chown root:roadwarrior /etc/swanctl/roadwarrior.conf
  chmod 640 /etc/swanctl/roadwarrior.conf

  # specifically allow rwctl subcommands rather than accepting all
  cat > /etc/sudoers.d/roadwarrior <<'SUDOERS'
roadwarrior ALL=(root) NOPASSWD: \
  /usr/local/bin/rwctl suspend *, \
  /usr/local/bin/rwctl unsuspend *, \
  /usr/local/bin/rwctl start, \
  /usr/local/bin/rwctl stop, \
  /usr/local/bin/rwctl restart, \
  /usr/local/bin/rwctl reboot, \
  /usr/local/bin/rwctl status, \
  /usr/local/bin/rwctl list
SUDOERS
  chmod 440 /etc/sudoers.d/roadwarrior

  # allow roadwarrior user to read the VICI socket (and stop perm reset on restart)
  mkdir -p /etc/systemd/system/strongswan.service.d
  cat > /etc/systemd/system/strongswan.service.d/vici-perms.conf <<'DROPIN'
[Service]
ExecStartPost=/bin/sh -c 'i=0; while [ ! -S /run/charon.vici ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; chown root:roadwarrior /run/charon.vici && chmod 660 /run/charon.vici'
DROPIN

  cp "$(dirname "$0")/roadwarrior-mqtt.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable roadwarrior-mqtt
  # apply socket permissions without needing strongswan restart
  if [ -S /run/charon.vici ]; then
    chown root:roadwarrior /run/charon.vici
    chmod 660 /run/charon.vici
  fi
  echo "MQTT daemon installed. Run 'sudo rwctl mqtt config' to configure and start."
}

if [[ "${MQTT_ONLY:-}" == "yes" || "${MQTT_ONLY:-}" == "y" ]]; then
  install_mqtt
  exit 0
fi

DEFAULT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
SWANCTL_DIR="/etc/swanctl"
CERT_LIFESPAN=3650

if [[ -z "${VPN_NAME:-}" ]]; then
  read -r -p "VPN hostname or IP [$DEFAULT_HOSTNAME]: " VPN_NAME
  VPN_NAME="${VPN_NAME:-$DEFAULT_HOSTNAME}"
fi

if [[ -z "${VPN_RANGE:-}" ]]; then
  read -r -p "Virtual IP pool for clients [172.16.10.0/24]: " VPN_RANGE
  VPN_RANGE="${VPN_RANGE:-172.16.10.0/24}"
fi

if [[ -z "${VPN_SPLIT_SUBNETS:-}" ]]; then
  read -r -p "LAN subnets for split-tunnel clients (blank to skip): " VPN_SPLIT_SUBNETS
fi

if [[ -z "${DNS_SERVERS:-}" ]]; then
  read -r -p "DNS servers to push to clients [1.1.1.1,8.8.8.8]: " DNS_SERVERS
  DNS_SERVERS="${DNS_SERVERS:-1.1.1.1,8.8.8.8}"
fi

if [[ -z "${ON_DEMAND_MODE:-}" ]]; then
  read -r -p "Default OnDemand mode for mobileconfigs (off/always/untrusted) [off]: " ON_DEMAND_MODE
  ON_DEMAND_MODE="${ON_DEMAND_MODE:-off}"
fi

if [[ "${ON_DEMAND_MODE}" == "untrusted" && -z "${ON_DEMAND_TRUSTED_SSIDS:-}" ]]; then
  read -r -p "Trusted SSIDs - VPN will not connect on these networks (blank to skip): " ON_DEMAND_TRUSTED_SSIDS
fi

if [[ -z "${ON_DEMAND_CELLULAR:-}" ]]; then
  read -r -p "Connect on cellular networks? [yes]: " ON_DEMAND_CELLULAR
  ON_DEMAND_CELLULAR="${ON_DEMAND_CELLULAR:-yes}"
fi

# -s to hide password input
if [[ -z "${CERT_PASSWORD:-}" ]]; then
  read -r -s -p "Fallback PKCS12 password for client bundles: " CERT_PASSWORD
  echo
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  charon-systemd \
  strongswan-swanctl \
  strongswan-pki \
  libcharon-extra-plugins \
  libstrongswan-extra-plugins \
  iptables \
  iptables-persistent

PKI=$(command -v pki 2>/dev/null || echo /usr/lib/ipsec/pki)

mkdir -p "${SWANCTL_DIR}"/{x509,x509ca,x509suspended,private,dist,conf.d}
chmod 700 "${SWANCTL_DIR}/private"

# ca key/cert
if [[ ! -f "${SWANCTL_DIR}/private/caKey.pem" ]]; then
  "$PKI" --gen --type rsa --size 4096 --outform pem \
    > "${SWANCTL_DIR}/private/caKey.pem"
  chmod 600 "${SWANCTL_DIR}/private/caKey.pem"
fi

if [[ ! -f "${SWANCTL_DIR}/x509ca/caCert.pem" ]]; then
  "$PKI" --self --ca \
    --in "${SWANCTL_DIR}/private/caKey.pem" --type rsa \
    --dn "C=NZ, O=roadwarrior, CN=${VPN_NAME} CA" \
    --lifetime "${CERT_LIFESPAN}" --digest sha256 \
    --outform pem \
    > "${SWANCTL_DIR}/x509ca/caCert.pem"

  openssl x509 \
    -in  "${SWANCTL_DIR}/x509ca/caCert.pem" \
    -out "${SWANCTL_DIR}/x509ca/caCert.der" \
    -outform DER
fi

# server key/cert
if [[ ! -f "${SWANCTL_DIR}/private/serverKey.pem" ]]; then
  "$PKI" --gen --type rsa --size 2048 --outform pem \
    > "${SWANCTL_DIR}/private/serverKey.pem"
  chmod 600 "${SWANCTL_DIR}/private/serverKey.pem"
fi

if [[ ! -f "${SWANCTL_DIR}/x509/serverCert.pem" ]]; then
  "$PKI" --pub --in "${SWANCTL_DIR}/private/serverKey.pem" --type rsa \
    | "$PKI" --issue \
        --cacert "${SWANCTL_DIR}/x509ca/caCert.pem" \
        --cakey  "${SWANCTL_DIR}/private/caKey.pem" \
        --dn "C=NZ, O=roadwarrior, CN=${VPN_NAME}" \
        --san "${VPN_NAME}" \
        --flag serverAuth \
        --flag ikeIntermediate \
        --lifetime "${CERT_LIFESPAN}" --digest sha256 \
        --outform pem \
    > "${SWANCTL_DIR}/x509/serverCert.pem"
fi


# updown script
cat > "${SWANCTL_DIR}/updown.sh" <<'UPDOWN'
#!/usr/bin/env bash
DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -1)
case "$PLUTO_VERB" in
  up-client|up-host)
    ip route replace "${PLUTO_PEER_CLIENT}" dev "${DEFAULT_IFACE}" 2>/dev/null || true
    ;;
  down-client|down-host)
    ip route del "${PLUTO_PEER_CLIENT}" dev "${DEFAULT_IFACE}" 2>/dev/null || true
    ;;
esac
UPDOWN
chmod 755 "${SWANCTL_DIR}/updown.sh"

# swanctl.conf. Now pools only. per-client connections handled by rwctl. (conf.d/client-<name>.conf)
cat > "${SWANCTL_DIR}/swanctl.conf" <<SWANCTL
pools {
  rw_pool {
    addrs = ${VPN_RANGE}
    dns   = ${DNS_SERVERS//,/, }
  }
}
SWANCTL

# roadwarrior config
cat > "${SWANCTL_DIR}/roadwarrior.conf" <<RWCONF
VPN_NAME="${VPN_NAME}"
VPN_RANGE="${VPN_RANGE}"
VPN_SPLIT_SUBNETS="${VPN_SPLIT_SUBNETS:-}"
DNS_SERVERS="${DNS_SERVERS}"
CERT_PASSWORD="${CERT_PASSWORD:-}"
CERT_LIFESPAN=${CERT_LIFESPAN}
PKI="${PKI}"
ON_DEMAND_MODE="${ON_DEMAND_MODE:-off}"
ON_DEMAND_TRUSTED_SSIDS="${ON_DEMAND_TRUSTED_SSIDS:-}"
ON_DEMAND_CELLULAR="${ON_DEMAND_CELLULAR:-yes}"
RWCONF
chmod 600 "${SWANCTL_DIR}/roadwarrior.conf"

# IP forward
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-roadwarrior.conf

# iptables MASQUERADE rule
if ! iptables -t nat -C POSTROUTING \
     -s "${VPN_RANGE}" ! -d "${VPN_RANGE}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING \
    -s "${VPN_RANGE}" ! -d "${VPN_RANGE}" -j MASQUERADE
fi

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# enable and  (re)start service
systemctl enable strongswan
systemctl restart strongswan
swanctl --load-all

install -m 755 "$(dirname "$0")/rwctl" /usr/local/bin/rwctl

# mqtt stuff
if [[ -z "${INSTALL_MQTT:-}" ]]; then
  read -r -p "Install MQTT daemon for Home Assistant integration? [y/N]: " INSTALL_MQTT
fi

if [[ "${INSTALL_MQTT,,}" == "y" || "${INSTALL_MQTT,,}" == "yes" ]]; then
  # move to new function
  install_mqtt
fi

echo ""
echo "Done. VPN_NAME=${VPN_NAME}, pool=${VPN_RANGE}"
echo "Note: TPM plugin warnings in the strongSwan log are expected if no TPM chip is present"
echo "Add clients with: rwctl add <name>"
