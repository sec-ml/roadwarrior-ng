# Changelog

## 1.0.4 - 2026-06-30

- Added CHANGELOG.md
- Added release workflow (`.github/workflows/release.yml`)

## 1.0.3 - 2026-06-30 (no release)

- Fixed suspend. Strongswan wasn't actually enforcing it, as it doesn't check cert presence at connection time. Each client now gets its own config entry; `suspend` removes the entry and reloads strongswan
- Per-client config template moved from `setup.sh` into `rwctl`
- MQTT install extracted to a reusable function so re-running setup won't fail if a previous attempt stopped partway through
- Sudoers updated to permit all `rwctl` subcommands (not just specific ones)
- Added systemd drop-in to preserve vici socket permissions across strongswan restarts

## 1.0.2 - 2026-06-27 (no release)

- `roadwarrior-client` renamed to `rwctl`
- Added `service` and `system` commands to `rwctl`
- Added MQTT monitoring and control via `rwmqtt`. Publishes client connection status, ISP/location, and transfer stats; subscribes to control commands
- Fixed vici socket handling and stale SA stats
- ISP detection switched from guessing mobile vs. broadband to reporting ASN org name
- Transfer byte reporting now uses the client's perspective (rx/tx), not the server's

## 1.0.1 - 2026-06-25 (no release)

- Fixed VPN hostname resolution for NAT/home network setups where the VPN hostname differs from the machine hostname
- `regen --password <pass>` now re-exports the `.p12` to reflect the updated password
- Added on-demand mode and trusted SSID support for Apple clients
- Added per-client split/full tunnel routing via `--routing` flag and `set-routing` command
- Added `suspend` and `unsuspend` commands. Suspension removes the client's CRL entry without `--clear`, avoiding a disconnect of all other clients
- Certificate files temporarily served over HTTP (60 second window) to simplify initial provisioning
- Added TPM warning on setup
- Added README.md

## 1.0.0 - 2026-06-24 (no release)

- Initial release: strongSwan IKEv2 VPN server setup (`setup.sh`) and client management (`roadwarrior-client`)
