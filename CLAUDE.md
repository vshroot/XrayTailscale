# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

XrayTailscale — automated Xray Reality VPN manager for bypassing DPI censorship in Russia. Single Bash script (`xraytailscale`, ~12k lines) built from modules in `src/`, turning a VPS into a managed VPN server with an interactive terminal UI. Deployed to Debian 10+/Ubuntu 20.04+ servers.

## Validation Commands

```bash
./build.sh                         # src/*.sh -> ./xraytailscale (name order)
bash -n xraytailscale              # Syntax check (MUST pass before commit)
bash -n install.sh update.sh uninstall.sh
for t in validation/test-*.sh; do bash "$t" || echo "FAIL: $t"; done
```

Tests in `validation/` are static (grep + `bash -n`) and behavioural (source a
module, call a function, assert rc/state) — they need no server. `test-build-sync.sh`
fails if the committed bundle differs from `src/`. Manual validation on a real
VPS is still needed for provisioning paths (certbot, nginx, firewall).

## Architecture

### Modular sources, single-file bundle

Logic lives in `src/*.sh` modules (see `src/README.md` for the map); `./build.sh`
concatenates them in filename order into the committed `xraytailscale` bundle.
Supporting scripts (`install.sh`, `update.sh`, `uninstall.sh`) handle lifecycle
but are not part of the runtime. Never edit `xraytailscale` directly — edit
`src/` and rebuild, or `test-build-sync.sh` fails.

### Production paths

- `/usr/local/etc/xray/config.json` — Xray configuration (inbounds, routing, DNS)
- `/usr/local/etc/xray/profiles/*.json` — per-user profile metadata
- `/usr/local/etc/xray/.private_key`, `.public_key` — Reality keys (generated once at install, never regenerated)
- `/usr/local/etc/xray/backups/` — timestamped config backups (created by `backup_config()`)
- `/usr/local/bin/xraytailscale` — symlink to the script
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

Marker files in `/usr/local/etc/xray/` (e.g. `.xhttp_migrated`, `.config_optimized`, `.pq_all_2026`). Migrations run once on first `main_menu()` launch after upgrade, through `run_migration <id> <description> <fn>` (`src/20-migrations.sh`), which already wraps `backup_config` and `safe_restart_xray`. A migration function returns **0 = changed, 1 = no-op, 2 = failed**, and must not do its own backup/restart. `pq_all_2026` (`_migrate_pq_all_profiles_2026`) upgrades legacy single-route profiles to XHTTP+PQ one by one through `_pq_upgrade_one_profile` (shared with the manual `upgrade_profile_to_pq_menu`).

Pattern for a migration body:
```bash
_my_migration() {
  # ... safe_jq_write calls ...
  fix_xray_permissions
  return 0   # 0=changed, 1=no-op, 2=failed (marker is NOT set, migration retries)
}
# Registered in main_menu(): run_migration "my_migration_marker" "Description" _my_migration
# run_migration sets the marker and restarts Xray only after a successful fn.
```

### Security model

Xray runs as non-root user `xray` with `CAP_NET_BIND_SERVICE` via systemd drop-in file. The `install.sh` creates the user and sets file ownership. The `safe_jq_write()` function preserves `644` permissions; `fix_xray_permissions()` restores ownership after writes.

### Add-on services (deprecated v2.0)

- **AdGuard Home** — Removed from the interactive menu in v2.0. If `/opt/AdGuardHome/AdGuardHome` is detected during `xraytailscale update`, update.sh force-uninstalls it through `_adguard_force_uninstall_if_present` after rolling Xray DNS back to DoH Local (`https+local://1.1.1.1/dns-query`). `uninstall_adguard_home()` remains in `xraytailscale` for manual emergency use.

## Coding Patterns

**Language**: Bash. Dependencies: `jq`, `curl`, `ufw`, `systemctl`, `openssl`, `uuidgen`, `qrencode`.

**Variables**: Always quote (`"$var"`), always `local` in functions.

**Safe JSON writes** — use `safe_jq_write()` for ALL jq modifications to config.json and profile files. It validates output is non-empty before `mv`, preventing data loss on jq errors:
```bash
safe_jq_write --arg uuid "$uuid" --argjson port "$port" \
  '(.inbounds[] | select(.port == $port) | .settings.clients) += [{"id": $uuid}]' \
  "$CONFIG_FILE"
```
Do NOT use raw `jq ... > temp && mv temp file` — always go through `safe_jq_write`. Note: `safe_jq_write` is only available inside `xraytailscale`; `install.sh` and `update.sh` use inline jq with `-s` size validation.

**jq argument passing**: Use `--argjson` for numeric ports, `--arg` for strings. Never interpolate variables into jq expressions.

**Error handling in create_profile**: `add_inbound()` can fail (transport conflict, SNI conflict rejection). `create_profile()` checks the return code and deletes the profile file on failure. Always check `add_inbound` return.

**Client counting**: When checking if an inbound has remaining clients (e.g. before deleting the entire inbound), count via `config.json` clients array, NOT by counting profile files on disk. Profile files can be out of sync.

**Menu pattern**: `while true; do show_ascii; ... read choice; case $choice in ... 0) return ;; esac; done`

**UI entry points** (`src/55-main-menu.sh`, `src/56-wizard.sh`, `src/57-status.sh`):
`main_menu()` is a router, not a 16-item list: `wizard_is_fresh_install` →
`run_first_run_wizard`, otherwise → `status_screen`. The status screen has
add-user / links+QR / diagnose-and-repair / «Дополнительно». Everything rare
(bulk users, Tailscale, cascade + bypass + outbound node, subscription
management, self-steal, advanced profile settings, user deletion, core update)
lives in `_status_extra_menu`. Bypass rules and the outbound-node setup are
sub-items of `cascade_mode_menu` — they only make sense with a cascade.

- `read` in every interactive function must tolerate EOF (`read -r x || return`)
  so the wizard can call menu functions non-interactively.
- Every provisioning step ends with an outside-in check; a step the user cannot
  see failing is a bug.
- State files (`.wizard_state`, `.subscription_port`) are untrusted input: re-validate
  values read back before they reach a path, `jq` filter or firewall command.

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
