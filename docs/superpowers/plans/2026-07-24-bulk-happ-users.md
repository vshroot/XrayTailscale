# Bulk HAPP Users Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bulk generation of per-user HAPP subscription URLs on one XrayTailscale VPS.

**Architecture:** Add bulk helpers to the existing `xraytailscale` manager and keep profile JSON compatibility with current multi-route HAPP subscriptions. A hidden `_bulk_seed.json` owns the shared routes; generated users copy those routes, get unique `uuid` and `sub_token`, and are added as clients to the shared route inbounds.

**Tech Stack:** Bash, `jq`, existing XrayTailscale profile JSON files, existing HAPP subscription handler.

## Global Constraints

- Do not generate full server `config.json` files for multiple VPS hosts.
- Do not create seven new ports per generated user.
- Do not replace the existing single-profile creation flow.
- Do not change the HAPP subscription URL format.
- Do not change existing profiles unless the operator explicitly revokes or deletes one.
- Bulk generation requires the HAPP subscription handler to be installed.
- Use a dedicated seed profile at `$PROFILES_DIR/_bulk_seed.json`.

---

### Task 1: Bulk Behavior Test

**Files:**
- Create: `validation/test-bulk-happ-users.sh`
- Modify: none

**Interfaces:**
- Consumes: existing source-safe `xraytailscale` functions and globals.
- Produces: a failing test that requires `bulk_generate_users_core`, `bulk_revoke_user_core`, `bulk_delete_user_core`, `bulk_print_users_urls_core`, `bulk_happ_users_menu`, and main-menu route `10`.

- [ ] **Step 1: Write the failing test**

```bash
bash validation/test-bulk-happ-users.sh
```

Expected before implementation: FAIL because `bulk_generate_users_core` is missing.

- [ ] **Step 2: Verify RED**

Run:

```bash
bash validation/test-bulk-happ-users.sh
```

Expected:

```text
missing bulk_generate_users_core
```

### Task 2: Bulk Core Helpers

**Files:**
- Modify: `xraytailscale`
- Test: `validation/test-bulk-happ-users.sh`

**Interfaces:**
- Produces:
  - `bulk_generate_users_core <prefix> <count> <batch_id>`
  - `bulk_print_users_urls_core <batch_id>`
  - `bulk_revoke_user_core <profile_name>`
  - `bulk_delete_user_core <profile_name>`
  - `_bulk_seed_profile_file`
  - `_bulk_ensure_dir`
  - `_bulk_seed_ready`

- [ ] **Step 1: Run failing test**

```bash
bash validation/test-bulk-happ-users.sh
```

- [ ] **Step 2: Implement helpers**

Add helpers that:

- Create `_bulk_seed.json` through `create_profile_all_routes "_bulk_seed" "no_pause" "hide_subscription"` when missing.
- Mark seed with `bulk_seed: true`.
- Generate target names as `prefix-001`, `prefix-002`, ...
- Validate all target names before mutation.
- Create one backup.
- Add each generated UUID to every route inbound.
- Write user profile JSON files with `bulk_managed: true`.
- Restart Xray once.
- Print generated subscription URLs after creation.
- Print saved subscription URLs later from profile JSON metadata.

- [ ] **Step 3: Verify GREEN**

```bash
bash validation/test-bulk-happ-users.sh
```

Expected: PASS.

### Task 3: Bulk Menu and Docs

**Files:**
- Modify: `xraytailscale`
- Modify: `README.md`
- Test: existing validation scripts

**Interfaces:**
- Produces:
  - `bulk_happ_users_menu`
  - main-menu item `10) Bulk HAPP users`

- [ ] **Step 1: Add menu**

Wire `bulk_happ_users_menu` into `main_menu` as option `10`.

- [ ] **Step 2: Add README section**

Document bulk generation, printed URL output, revoke versus delete, and the shared multi-route model.

- [ ] **Step 3: Verify regression tests**

Run:

```bash
bash -n xraytailscale install.sh update.sh uninstall.sh
bash validation/test-bulk-happ-users.sh
bash validation/test-vless-url-generation.sh
bash validation/test-multiroute-xhttp-path-generation.sh
bash validation/test-xhttp-path-sync-migration.sh
bash validation/test-happ-subscription-static.sh
bash validation/test-tailscale-exit-node-static.sh
bash validation/test-cascade-routing.sh
bash validation/test-update-xray-core-sync.sh
bash validation/test-mutation-safety-static.sh
bash validation/test-xraytailscale-branding-static.sh
git diff --check
```

Expected: all pass.
