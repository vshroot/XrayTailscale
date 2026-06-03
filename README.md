# XrayTailscale

XrayTailscale is a VPS setup and management script for a personal Xray Reality server with optional HAPP subscriptions, multi-route VLESS profiles, post-quantum XHTTP routes, bypass routing, and a Tailscale exit node.

The project is designed for one-person or small private deployments. It installs Xray-core, creates and manages VLESS Reality inbounds, serves subscription URLs over HTTPS, and can join the VPS to your Tailscale tailnet as an exit node.

## What It Installs

- Latest Xray-core for Linux.
- Interactive manager command: `xraytailscale`.
- Update command: `xraytailscale-update`.
- Uninstall command: `xraytailscale-uninstall`.
- Optional HAPP subscription service: `xraytailscale-sub.service`.
- Nginx HTTPS frontend for subscription URLs.
- Optional Tailscale exit-node configuration.
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

## Tailscale Exit Node

Open the manager:

```bash
sudo xraytailscale
```

Choose:

```text
12) Tailscale exit node
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
10) Update Xray-core
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
bash validation/test-happ-subscription-static.sh
bash validation/test-update-xray-core-sync.sh
bash validation/test-mutation-safety-static.sh
bash validation/test-tailscale-exit-node-static.sh
bash validation/test-xraytailscale-branding-static.sh
```

## License

MIT. See [LICENSE](LICENSE).
