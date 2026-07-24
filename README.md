# XrayTailscale

XrayTailscale is a VPS setup and management script for a personal Xray Reality server with optional HAPP subscriptions, multi-route VLESS profiles, post-quantum XHTTP routes, bypass routing, cascade upstream routing, and a Tailscale exit node.

The project is designed for one-person or small private deployments. It installs Xray-core, creates and manages VLESS Reality inbounds, serves subscription URLs over HTTPS, and can join the VPS to your Tailscale tailnet as an exit node.

## What It Installs

- Latest Xray-core for Linux.
- Interactive manager command: `xraytailscale`.
- Update command: `xraytailscale-update`.
- Uninstall command: `xraytailscale-uninstall`.
- Optional HAPP subscription service: `xraytailscale-sub.service`.
- Nginx HTTPS frontend for subscription URLs.
- Optional Tailscale exit-node configuration.
- Optional cascade routing through a separate upstream VLESS Reality node.
- UFW firewall rules for SSH, HTTPS, subscription ports, and Xray routes.
- BBR TCP tuning and geodata files for routing.

## Requirements

- Debian 10+ or Ubuntu 20.04+.
- Root access or a user with `sudo`.
- 512 MB RAM minimum, 1 GB+ recommended.
- A public IPv4 VPS.
- Ports `22`, `80`, and `443` reachable during installation.
- A domain is optional, but recommended for long-term subscription use.

## One-Command Deploy

Run this on a fresh VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/vshroot/XrayTailscale/main/install.sh | sudo bash
```

Alternative with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/vshroot/XrayTailscale/main/install.sh | sudo bash
```

After installation, open the manager:

```bash
sudo xraytailscale
```

## Main Menu

The manager is interactive. The most important options are:

| Option | Purpose |
| --- | --- |
| `1` | Create a new VLESS profile manually. |
| `2` | Delete an existing profile and its unused inbounds. |
| `3` | Show raw connection data for a profile. |
| `4` | Manage profile SNI, fingerprint, port, and advanced settings. |
| `8` | Upgrade a legacy profile to post-quantum XHTTP. |
| `9` | Create or manage a HAPP subscription profile. |
| `10` | Update Xray-core. |
| `11` | Manage bypass routing rules. |
| `12` | Install and configure Tailscale as an exit node. |
| `13` | Configure cascade routing through an upstream node. |
| `14` | Create an outbound-server node on a separate overseas VPS. |
| `15` | Generate and manage bulk HAPP multi-route users. |

## HAPP Subscription Setup

Open the manager:

```bash
sudo xraytailscale
```

Choose:

```text
9) HAPP subscription
```

You can create a public subscription by VPS IP or by domain. Domain mode is better for daily use. The script creates a multi-route profile and returns a subscription URL like:

```text
https://your-domain.example/sub/<token>
```

or:

```text
https://your-vps-ip/sub/<token>
```

Import that URL into HAPP. The subscription endpoint serves a conservative text list of VLESS routes for HAPP and a v2ray-compatible base64 body for clients such as v2rayNG or v2rayN.

The generated multi-route profile can include:

- TCP Reality / Vision route.
- TCP Reality fallback routes.
- gRPC Reality route.
- XHTTP legacy fallback route.
- XHTTP post-quantum route with `mlkem768x25519plus`.

If the subscription URL leaks, revoke it from the HAPP subscription menu. Revocation rotates the profile token.

## Bulk HAPP Users

Bulk HAPP users are for issuing many separate subscription URLs on one VPS without opening a new set of ports per user.

Open the manager:

```bash
sudo xraytailscale
```

Choose:

```text
10) Bulk HAPP users
```

The bulk generator creates one hidden shared multi-route seed profile named `_bulk_seed`, then creates normal user profiles such as:

```text
user-001
user-002
user-003
```

Each user gets a unique `uuid` and `sub_token`, but all users reuse the same multi-route ports and route metadata. Xray stores these users as separate clients inside the shared route inbounds.

If the hidden `_bulk_seed` profile points to ports that no longer exist in the live Xray config, the manager recreates the seed automatically before generating a new batch.

After generation the manager prints the generated subscription URLs immediately:

```text
Batch: bulk-20260724-153000
name subscription_url
user-001 https://your-domain.example/sub/<token>
user-002 https://your-domain.example/sub/<token>
```

Use `Show/print user URLs` later to print the same URLs again from saved profile metadata. The manager lists existing batches by number, so you do not need to remember the batch id manually.

Use `Revoke one user` to rotate only the subscription URL token. Use `Delete one user` to actually disable that user by removing their UUID from every shared multi-route inbound.

## Tailscale Exit Node

Open the manager:

```bash
sudo xraytailscale
```

Choose:

```text
13) Tailscale exit node
```

The script installs Tailscale, enables IP forwarding, starts `tailscaled`, and advertises the VPS as an exit node.

You still need to approve the exit-node capability in the Tailscale admin console:

```text
Machines -> your VPS -> Edit route settings -> Use as exit node
```

You can authenticate in two ways:

- Paste a reusable or one-off Tailscale auth key into the hidden prompt.
- Leave the auth key empty and follow the login URL printed by `tailscale up`.

The auth key is not saved by XrayTailscale.

## Cascade Routing

Cascade mode is server-side routing. Client profiles and HAPP subscription URLs stay on the main VPS, while Xray forwards default `tcp,udp` traffic through a separate upstream VLESS Reality server:

```text
client -> main VPS -> upstream VPS -> internet
```

On the upstream VPS, install XrayTailscale and choose:

```text
15) Create outbound server
```

This creates a TCP Reality Vision inbound and prints the values needed by the main VPS: host, port, UUID, public key, short ID, SNI, fingerprint, and flow.

On the main VPS, choose:

```text
14) Cascade / upstream nodes
```

Enter the upstream values, then enable cascade mode. XrayTailscale stores the upstream config in `/usr/local/etc/xray/upstreams/cascade.json`, adds `cascade-upstream` and `cascade-fragment` outbounds, and switches only the default catch-all `tcp,udp` route to the cascade outbound. Existing bypass rules stay above the catch-all rule and continue to go direct.

Disabling cascade removes the cascade outbounds and returns the catch-all route to `direct`. Existing client profiles, HAPP subscriptions, XHTTP paths, Reality keys, and Tailscale settings are not changed.

## Updates

Update XrayTailscale scripts:

```bash
sudo xraytailscale-update
```

Force update from the stable branch:

```bash
sudo xraytailscale-update main
```

Update only Xray-core:

```bash
sudo xraytailscale
```

Then choose:

```text
11) Update Xray-core
```

## Uninstall

Remove XrayTailscale and Xray:

```bash
sudo xraytailscale-uninstall
```

This removes the manager, Xray configuration, profiles, scripts, and systemd units created by the installer.

## Useful Diagnostics

Check Xray:

```bash
sudo systemctl status xray --no-pager -l
sudo journalctl -u xray -n 80 --no-pager
```

Check the subscription service:

```bash
sudo systemctl status xraytailscale-sub --no-pager -l
sudo journalctl -u xraytailscale-sub -n 80 --no-pager
```

Test a subscription URL from the VPS:

```bash
curl -vk https://your-domain.example/sub/<token>
```

Run the built-in SNI probe:

```bash
sudo xraytailscale probe-test
```

## Security Notes

- Keep SSH access outside your own VPN route while changing server settings.
- Do not publish subscription URLs.
- Use the revoke action if a subscription URL is shared accidentally.
- Keep a working SSH key before disabling password login.
- For public deployments, prefer a dedicated VPS and a dedicated domain.
- Tailscale exit-node approval must be done in your own Tailscale admin console.

## Development Checks

From the repository root:

```bash
bash -n xraytailscale install.sh update.sh uninstall.sh
bash validation/test-vless-url-generation.sh
bash validation/test-bulk-happ-users.sh
bash validation/test-cascade-routing.sh
bash validation/test-happ-subscription-static.sh
bash validation/test-multiroute-xhttp-path-generation.sh
bash validation/test-xhttp-path-sync-migration.sh
bash validation/test-update-xray-core-sync.sh
bash validation/test-mutation-safety-static.sh
bash validation/test-tailscale-exit-node-static.sh
bash validation/test-xraytailscale-branding-static.sh
```

## License

MIT. See [LICENSE](LICENSE).
