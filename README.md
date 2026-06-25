# roadwarrior-ng

IKEv2 VPN server for home LAN access. Designed mainly for iOS/macOS using `.mobileconfig` profiles.

This [PR](https://github.com/sec-ml/puppet-roadwarrior/tree/main) just about works but uses `ipsec` instead of the newer `swanctl`. The latter allows for better montoring and client-level control (planned features).

Inspired by `jethrocarr/puppet-roadwarrior`, and the same approach is generally used so far.

---

## Requirements

- Debian or Ubuntu server (initial testing: works on LXC unpriviliged container)
- A public hostname or IP pointing to the server (or port-forwarded from your router)
- UDP ports 500 and 4500 open/forwarded

---

## Future features & ideas

- Proxmox container setup script
- MQTT + Home Assistant discovery: per-client connected status, last IP, location, bytes; actions: disconnect/suspend/revoke; system commands: restart/reboot/update
- Let's Encrypt server cert (Cloudflare DNS challenge). Removes need for CA cert in mobileconfig
- Cloudflare DNS / DDNS support
- Proper revocation (current `revoke` only deletes files)
- Logging (updown hook triggers to syslog on connects/disconnects)
- Per-client onward/exit routing
- Android & Windows support
- Better distribution of cert filess
- Per-client state file to track routing mode, on-demand settings etc. so `list` can show them and `regen` can preserve them without re-specifying flags

## Setup

```bash
git clone https://github.com/sec-ml/roadwarrior-ng.git && cd roadwarrior-ng
sudo ./setup.sh
```

Setup prompts:

| Prompt | Default | Notes |
|---|---|---|
| VPN hostname or IP | system hostname | must be reachable by clients |
| Virtual IP pool | 172.16.10.0/24 | assigned to connected clients; must not overlap your LAN |
| LAN subnets for split tunnel | (blank) | e.g. `192.168.1.0/24,192.168.10.0/24`; blank = full tunnel only |
| DNS servers | 1.1.1.1,8.8.8.8 | pushed to clients on connect |
| OnDemand mode | off | `off`/`always`/`untrusted` |
| Trusted SSIDs | (blank) | only shown if OnDemand mode is `untrusted` |
| Connect on cellular | yes | |
| Fallback PKCS12 password | (required) | used for client bundles if no per-client password is set |

All values can be set as environment variables (to support future proxmox container script automation):

```bash
sudo VPN_NAME=vpn.example.com VPN_RANGE=172.16.10.0/24 bash setup.sh
```

Config saved to `/etc/swanctl/roadwarrior.conf`, used by `roadwarrior-client` for client generation/management.

---

## Managing clients

### Add a client

```bash
sudo ./roadwarrior-client add <name>
```

Generates a key, certificate, PKCS12 bundle, and mobileconfig. Files are written to `/etc/swanctl/dist/<name>/`.

Options:

| Flag | Notes |
|---|---|
| `--password <pass>` | set PKCS12 password (default: fallback from setup, or random) |
| `--embed-password` | embed password in mobileconfig (iOS won't prompt on install) |
| `--on-demand off\|always\|untrusted` | override server default |
| `--trusted-ssids <ssids>` | comma-separated SSIDs where VPN disconnects (untrusted mode) |
| `--cellular yes\|no` | whether to connect on cellular |
| `--routing full\|split` | tunnel mode (default: full) |

### Serve profile

```bash
sudo ./roadwarrior-client serve <name>
```

Serves the client's dist directory over HTTP for 60 seconds. Browse to the printed URL from the target device to download the mobileconfig.

```bash
# & to specify port:
sudo ./roadwarrior-client serve <name> --port 9000
```

### Regenerate mobileconfig

```bash
sudo ./roadwarrior-client regen <name>
```

Rebuilds the mobileconfig from the existing certificate. Use this if changing OnDemand settings. Supports the same flags as `add`. If `--password` is set, the PKCS12 is also re-exported with new password.

### Revoke a client

```bash
sudo ./roadwarrior-client revoke <name>
```

Removes all files for the client and terminates any active session.

### List clients

```bash
# lists client certs in /etc/swanctl/x509/
sudo ./roadwarrior-client list
```

### Show active connections

```bash
sudo ./roadwarrior-client status
# Replicates: swanctl --list-sas 
```

---

## Routing modes

Routing is controlled server-side via the `local_ts` traffic selector. No mobileconfig changes are needed. This can allow changes on the fly (future features, MQTT control).

| Mode | Behaviour |
|---|---|
| Full tunnel | all traffic routed via VPN (default) |
| Split tunnel | only LAN subnets routed via VPN |

Split tunnel requires `VPN_SPLIT_SUBNETS` to be set during setup. Assign a client at creation time with `--routing split`, or change it later:

```bash
sudo ./roadwarrior-client set-routing <name> split
sudo ./roadwarrior-client set-routing <name> full
```

---

## iOS/macOS install

1. Run `roadwarrior-client serve <name>`
2. Open the URL on the device (while connected to LAN...)
3. Download and open the `.mobileconfig` file
4. Go to Settings > General > VPN & Device Management to install
5. Enter the PKCS12 password when prompted (if not embedded)

---

## Logging / troubleshooting

```bash
journalctl -u strongswan -f
```

Above command will follow connection. Run it, then try to connect with the client. If you don't see a connection attempt, check your network settings/port forwarding.

Note: TPM plugin warnings on startup are likely if the server has no TPM chip (which VMs, containers won't have).
