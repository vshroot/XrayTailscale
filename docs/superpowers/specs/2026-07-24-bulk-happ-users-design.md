# Bulk HAPP Users Design

## Goal

Add bulk generation of per-user HAPP subscription URLs on one XrayTailscale VPS.

The feature creates many independent user profiles with separate `uuid` and `sub_token` values, while reusing one shared multi-route inbound set. This avoids opening a new group of ports for every user.

## Non-Goals

- Do not generate full server `config.json` files for multiple VPS hosts.
- Do not create seven new ports per generated user.
- Do not replace the existing single-profile creation flow.
- Do not change the HAPP subscription URL format.
- Do not change existing profiles unless the operator explicitly revokes or deletes one.

## User Interface

Add a main-menu item:

```text
10) Bulk HAPP users
```

The submenu exposes:

```text
1) Generate users
2) Show/print user URLs
3) Revoke one user
4) Delete one user
0) Back
```

The generation flow asks for:

- Number of users.
- Profile name prefix.
- Template, initially only `multi-route HAPP`.

Generation requires the HAPP subscription handler to be installed. If the current subscription mode is local-only, the script should warn that generated URLs are local debug URLs.

Generated names use zero-padded suffixes:

```text
user-001
user-002
user-003
```

If a name already exists, generation stops before mutating `config.json`.

## Data Model

Each generated user remains a normal profile JSON in `PROFILES_DIR`.

The profile format is compatible with existing multi-route profiles:

```json
{
  "name": "user-001",
  "uuid": "...",
  "schema_version": 3,
  "multi_route": true,
  "bulk_managed": true,
  "bulk_batch_id": "bulk-20260724-153000",
  "primary_route": "xhttp-legacy",
  "sub_token": "...",
  "created": "2026-07-24 15:30:00",
  "routes": []
}
```

The `routes` array points to shared inbound ports and transport metadata. Each user has different credentials, not different ports.

If the hidden seed profile exists but references ports that are no longer present in the live Xray config, the manager recreates `_bulk_seed` before generating a new batch.

If existing bulk users reference stale ports and their subscription endpoint returns `410 Gone`, `bulk_repair_stale_users_core` rewrites those bulk-managed profile routes to the current seed routes, preserves `uuid`/`sub_token`, adds the UUIDs to live inbounds, and restarts Xray once.

The manager prints generated URLs immediately after successful creation:

```text
Batch: bulk-20260724-153000
name subscription_url
user-001 https://your-domain.example/sub/<token>
user-002 https://your-domain.example/sub/<token>
```

The same URLs can be printed later from saved profile JSON metadata. The print flow lists available batches and lets the operator select one by number, with an `all` option for printing every bulk-managed user.

## Shared Routes

Bulk generation requires one shared multi-route inbound set. The script should:

1. Reuse the dedicated bulk seed profile if it already exists.
2. Otherwise create one hidden seed multi-route profile at `$PROFILES_DIR/_bulk_seed.json`.
3. Copy the seed profile routes into each generated user profile.
4. Add every generated user UUID to each shared inbound client list.

The seed profile should be marked:

```json
{
  "name": "_bulk_seed",
  "bulk_seed": true
}
```

The seed profile exists to define shared routes. It should not be shown as an ordinary generated end-user in bulk URL output or ordinary profile selection menus.

## Mutation Strategy

Bulk generation must be atomic from the operator's perspective:

- Validate input before mutation.
- Check all target names before mutation.
- Create one `config.json` backup before mutation.
- Write all profile JSON files.
- Add all UUIDs to all shared inbound client arrays.
- Run `safe_restart_xray` once.
- If restart fails, remove generated profile JSON files and rely on the existing `safe_restart_xray` rollback for `config.json`.

Firewall changes should only occur when the seed multi-route profile is created. Adding more users to existing shared inbounds should not open new ports.

## Revoke

Bulk revoke rotates only the selected profile's `sub_token`.

It does not change the user's `uuid`, shared inbounds, or routes. Existing HAPP subscription handler behavior already reads profile JSON on each request, so no Xray restart is required.

## Delete

Bulk delete removes a selected bulk-managed profile and removes its UUID from every shared route inbound's `settings.clients`.

It must:

- Create a config backup.
- Remove the UUID from the relevant inbounds.
- Restart Xray once.
- Delete the profile JSON only after successful restart.

Seed profile deletion is not part of this feature.

## Error Handling

The feature should fail early for:

- Invalid count.
- Empty or invalid prefix.
- Existing target profile names.
- Missing route metadata.
- Missing subscription base configuration.
- Xray restart failure.

Failures must print actionable messages and avoid leaving partially generated user profiles.

## Testing

Add validation coverage for:

- Bulk menu functions exist and are routed from main menu.
- Generated profiles have unique `uuid` and `sub_token` values.
- Generated profiles reuse the same route ports.
- Shared inbound client arrays receive all generated UUIDs.
- Bulk generation restarts Xray once.
- Revoke changes only `sub_token`.
- Delete removes the profile only after config restart succeeds.
- Existing XHTTP path and HAPP subscription tests continue to pass.
