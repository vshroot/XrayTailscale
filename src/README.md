# xraytailscale sources (modules)

The `xraytailscale` file in the repo root is the **built** single-file.
Edit the modules here, then rebuild:

```bash
./build.sh                              # rebuild xraytailscale
bash validation/test-build-sync.sh      # verify there is no drift
```

Modules are concatenated in file-name sort order.
Function order in the built file equals the original monolith order,
so the build reproduces the previous behaviour one-for-one.

## Module map

| File | Contents |
| --- | --- |
| `00-core.sh` | Constants, paths, colors, source-safety guard, root-check, `github_raw_curl`, `get_server_ip` |
| `05-profile-utils.sh` | Transport metadata, VLESS URL generation, `update_transport_settings_for_sni`, subscription base URLs |
| `10-system.sh` | `safe_jq_write`, backups/rollbacks, systemd unit, `safe_restart_xray`, UFW |
| `15-profile-sync.sh` | Per-port profile sync, SNI/fingerprint/port metadata updates |
| `20-migrations.sh` | Migrations (host tuning, Reality, XHTTP, routing, mlkem) |
| `25-sni-bypass-core.sh` | Bypass rule core, SNI probe |
| `30-ui-update.sh` | ASCII/banner, Xray-core update, `xraytailscale-update` |
| `35-subscription.sh` | HAPP subscription server, TLS (IP/domain), subscription menus |
| `40-bulk-happ.sh` | Bulk HAPP users: seed, generation, revoke/delete, repair |
| `45-tailscale.sh` | Tailscale exit node |
| `50-cascade.sh` | Cascade upstream, outbound-server node |
| `55-main-menu.sh` | Main menu |
| `60-profile-create.sh` | Profile creation, multi-route, `add_inbound` |
| `65-profile-manage.sh` | Profile delete/connect, SNI/fingerprint/port changes |
| `70-bypass-menu.sh` | Bypass routing menu |
| `75-pq-adguard.sh` | Post-quantum upgrade, emergency AdGuard removal |
| `80-domain.sh` | Server domain: storage and auto-fill |
| `85-selfsteal.sh` | Self-steal: your site + nginx + Let's Encrypt + Reality dest |
| `99-dispatch.sh` | CLI dispatch (subcommands, main_menu) |

## Rules

- Do not add top-level side effects to modules: top-level code runs on
  source (tests source the built file). Interactive code lives only in functions.
- A new module = a new `NN-name.sh` file with a fitting number, then `./build.sh`.
- After any edit: `./build.sh && bash validation/test-build-sync.sh`
  plus the full run of `validation/*.sh`.
