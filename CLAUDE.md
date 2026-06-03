# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Xrayebator — automated Xray Reality VPN manager for bypassing DPI censorship in Russia. Single Bash script (`xrayebator`, ~2500 lines) that turns a VPS into a managed VPN server with interactive terminal UI. Deployed to Debian 10+/Ubuntu 20.04+ servers.

## Validation Commands

```bash
bash -n xrayebator              # Syntax check (MUST pass before commit)
bash -n install.sh              # Also check lifecycle scripts
bash -n update.sh
```

There are no automated tests. Validation is manual: create/delete profiles, check `ufw status`, `systemctl status xray`, test connections from client apps (v2rayNG, Shadowrocket).

## Architecture

### Single-file application

All logic lives in `xrayebator`. Supporting scripts (`install.sh`, `update.sh`, `uninstall.sh`) handle lifecycle but are not part of the runtime.

### Production paths

- `/usr/local/etc/xray/config.json` — Xray configuration (inbounds, routing, DNS)
- `/usr/local/etc/xray/profiles/*.json` — per-user profile metadata
- `/usr/local/etc/xray/.private_key`, `.public_key` — Reality keys (generated once at install, never regenerated)
- `/usr/local/etc/xray/backups/` — timestamped config backups (created by `backup_config()`)
- `/usr/local/bin/xrayebator` — symlink to the script
- `/etc/systemd/system/xray.service.d/security.conf` — drop-in: `User=xray`, `CAP_NET_BIND_SERVICE`

### Critical concept: Inbound vs Profile

An **inbound** is a port-level config block in `config.json` (tag: `inbound-443`). A **profile** is a user-facing JSON file with UUID/transport/SNI metadata. Multiple profiles can share one inbound (same port). SNI and fingerprint are **inbound-level** — changing them affects ALL profiles on that port. The function `update_all_profiles_on_port()` keeps profile JSONs in sync.

### Transport compatibility and flow

All TCP sub-types (`tcp`, `tcp-utls`, `tcp-xudp`, `tcp-mux`) map to network `"tcp"` and can coexist on one inbound (same port). But they require different `flow` values per client:

| Transport | network | flow |
|-----------|---------|------|
| tcp, tcp-utls, tcp-xudp | tcp | `xtls-rprx-vision` |
| tcp-mux | tcp | `""` (empty) |
| grpc | grpc | `""` (empty) |
| xhttp | xhttp | `""` (empty) |

Flow is determined by transport type in `add_inbound()`, NOT copied from existing clients. Mixing Vision and non-Vision transports on one port is valid — each client gets its own flow.

### XHTTP special case

XHTTP transport stores SNI in TWO places: `realitySettings.serverNames` AND `xhttpSettings.host`. Both MUST match. The function `update_transport_settings_for_sni()` handles this.

### Firewall port management

- `open_firewall_port(port, proto)` — idempotent, validates port, checks UFW
- `close_firewall_port(port, proto)` — only closes if port unused by any Xray inbound AND not in default ports list (22, 80, 443, 8443, 2053, etc.)

### Safe restart and backup

- `safe_restart_xray()` — validates config with `xray run -test -config` before `systemctl restart`. On failure: auto-rollback from latest backup, Xray keeps running on old config. **Always use this instead of bare `systemctl restart xray`**.
- `backup_config("migration_name")` — creates timestamped backup in `/usr/local/etc/xray/backups/`. **Call before any config mutation** in migration functions.
- `fix_xray_permissions()` — restores `xray:xray` ownership on `/usr/local/etc/xray/`. Call after writes that create/modify files.

### Migration system

Marker files in `/usr/local/etc/xray/` (e.g. `.xhttp_migrated`, `.config_optimized`). Migrations run once on first `main_menu()` launch after upgrade. Pattern for new migrations:
```bash
if [[ ! -f "/usr/local/etc/xray/.my_migration_marker" ]]; then
  backup_config "my_migration"
  # ... safe_jq_write calls ...
  fix_xray_permissions
  touch "/usr/local/etc/xray/.my_migration_marker"
  safe_restart_xray
fi
```

### Security model

Xray runs as non-root user `xray` with `CAP_NET_BIND_SERVICE` via systemd drop-in file. The `install.sh` creates the user and sets file ownership. The `safe_jq_write()` function preserves `644` permissions; `fix_xray_permissions()` restores ownership after writes.

### Add-on services (deprecated v2.0)

- **AdGuard Home** — Removed from the interactive menu in v2.0. If `/opt/AdGuardHome/AdGuardHome` is detected during `xrayebator update`, update.sh force-uninstalls it through `_adguard_force_uninstall_if_present` after rolling Xray DNS back to DoH Local (`https+local://1.1.1.1/dns-query`). `uninstall_adguard_home()` remains in `xrayebator` for manual emergency use.

## Coding Patterns

**Language**: Bash. Dependencies: `jq`, `curl`, `ufw`, `systemctl`, `openssl`, `uuidgen`, `qrencode`.

**Variables**: Always quote (`"$var"`), always `local` in functions.

**Safe JSON writes** — use `safe_jq_write()` for ALL jq modifications to config.json and profile files. It validates output is non-empty before `mv`, preventing data loss on jq errors:
```bash
safe_jq_write --arg uuid "$uuid" --argjson port "$port" \
  '(.inbounds[] | select(.port == $port) | .settings.clients) += [{"id": $uuid}]' \
  "$CONFIG_FILE"
```
Do NOT use raw `jq ... > temp && mv temp file` — always go through `safe_jq_write`. Note: `safe_jq_write` is only available inside `xrayebator`; `install.sh` and `update.sh` use inline jq with `-s` size validation.

**jq argument passing**: Use `--argjson` for numeric ports, `--arg` for strings. Never interpolate variables into jq expressions.

**Error handling in create_profile**: `add_inbound()` can fail (transport conflict, SNI conflict rejection). `create_profile()` checks the return code and deletes the profile file on failure. Always check `add_inbound` return.

**Client counting**: When checking if an inbound has remaining clients (e.g. before deleting the entire inbound), count via `config.json` clients array, NOT by counting profile files on disk. Profile files can be out of sync.

**Menu pattern**: `while true; do show_ascii; ... read choice; case $choice in ... 0) return ;; esac; done`

**Colors**: `RED` (errors), `GREEN` (success), `YELLOW` (warnings/prompts), `BLUE` (menu borders), `CYAN` (info/options), `MAGENTA` (section headers), `NC` (reset).

**Port validation**: `[[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]`

**Restart discipline**: Never use bare `systemctl restart xray`. Always use `safe_restart_xray()` which validates config first and auto-rolls back on failure.

**Freedom outbound**: When modifying freedom outbound settings, use jq path assignment (not object merge) to avoid clobbering existing `fragment` anti-DPI settings.

## Branches

- `main` — stable, releases every 1-2 months
- `dev` — quick fixes, weekly
- `experimental` — latest features, daily (current working branch)

## Language

All user-facing strings, comments, and commit messages are in **Russian**. Code identifiers and function names are in English.
