# OAuth2 App Code Validation Plugin Design

## Status

Approved in design discussion on 2026-07-28.

## Context

`bk-oauth2-verify` validates an OAuth2 access token and stores its application
code in `ctx.var.bk_app_code`. The gateway needs a separate policy plugin that
allows OAuth2 requests only when that application code is one of the globally
enabled special client types:

- `public`
- `personal`

This policy is independent of audience validation. The new plugin will run
after `bk-oauth2-audience-validate` and will not change legacy, non-OAuth2
authentication.

## Goals

- Add a self-contained plugin named `bk-oauth2-appcode-validate`.
- Read `support_public` and `support_personal` from APISIX `plugin_attr`.
- Build the effective application-code allowlist during plugin initialization.
- Fail closed when configuration is absent or invalid.
- Reject an OAuth2 token whose application code is not allowed.
- Return caller-visible support status and emit diagnostic logs without logging
  token contents.
- Cover initialization and request behavior with Busted and test-nginx tests.

## Non-Goals

- Allow arbitrary application codes.
- Add route-level configuration.
- Change token verification, audience validation, or legacy authentication.
- Change `bk-oauth2-protected-resource`.
- Add control-plane or chart configuration in this change.

## Plugin Contract

### Identity and Ordering

- Name: `bk-oauth2-appcode-validate`
- Phase: `rewrite`
- Priority: `17677`

The resulting OAuth2 request order is:

1. `bk-oauth2-verify`
2. `bk-oauth2-audience-validate`
3. `bk-oauth2-appcode-validate`

If both audience and application code are invalid, audience validation returns
first.

### Route Schema

The route-level plugin schema is empty. Enabling the plugin on a route activates
the global application-code policy; a route cannot override it.

### Plugin Attributes

```yaml
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: false
    support_personal: false
```

The plugin exposes an `attr_schema` containing:

| Field | Type | Default |
| --- | --- | --- |
| `support_public` | boolean | `false` |
| `support_personal` | boolean | `false` |

## Initialization

`_M.init()` reads `plugin.plugin_attr(plugin_name)` and validates it against
`attr_schema`. Each invocation first resets all derived state so APISIX plugin
reloads cannot retain stale allowed values.

For valid configuration:

- `support_public == true` adds `public` to `allowed_app_codes`.
- `support_personal == true` adds `personal` to `allowed_app_codes`.

`allowed_app_codes` is a module-level hash set for constant-time request lookup.

When attributes are absent, both support flags are false and the set is empty.
When attributes are invalid, initialization logs the schema error, resets both
support flags to false, keeps the set empty, and leaves request validation
active. This is fail-closed behavior.

Initialization logs the effective support flags and generated allowlist.

## Request Processing

`_M.rewrite(conf, ctx)` behaves as follows:

1. If `ctx.var.is_bk_oauth2 ~= true`, log the skip reason and return without
   changing the request.
2. Read `ctx.var.bk_app_code`, which is populated by `bk-oauth2-verify`.
3. Log the requested application code and current support flags.
4. If the application code exists in `allowed_app_codes`, log success and
   return.
5. Otherwise, reject the request as an invalid token.

Missing, empty, ordinary, disabled, and unknown application codes all follow
the same rejection path. With both flags false, every OAuth2 request is
rejected.

## Failure Contract

A rejected application code returns:

- HTTP status: `401`
- APIGW error: `UNAUTHORIZED`
- `WWW-Authenticate` error: `invalid_token`

The APIGW error is created with `errorx.new_general_unauthorized()` and enriched
through `with_fields` with:

- `reason = "OAuth2 token app code is not allowed"`
- `bk_app_code`
- `support_public`
- `support_personal`

The `WWW-Authenticate` error description states that the current token
application code is unsupported and includes the effective public and personal
support statuses. The rejection log contains the same diagnostic context.

The plugin never logs the access token or other credentials.

## Test Design

### Busted

The Busted suite will cover:

- Empty route configuration is accepted.
- Attribute booleans are accepted and non-booleans are rejected.
- Initialization with absent attributes produces an empty set.
- Public-only, personal-only, and both-enabled initialization.
- Invalid attributes fail closed and log the schema failure.
- Re-initialization rebuilds state without retaining previous entries.
- Non-OAuth2 requests are skipped.
- Enabled `public` and `personal` application codes pass.
- Disabled, ordinary, missing, and empty application codes fail.
- Rejection returns 401 and populates the APIGW error.
- `WWW-Authenticate` contains `invalid_token`, the requested application code,
  and both support statuses.
- Initialization, success, and failure logs contain the required context and no
  token data.

Private state or helper access required for focused tests will be exposed only
under `_TEST`, following repository conventions.

### test-nginx

The test-nginx suite will use per-case `extra_yaml_config` to exercise real
`plugin_attr` initialization:

- Public-only configuration allows `public` and rejects `personal`.
- Personal-only configuration allows `personal` and rejects `public`.
- Both-enabled configuration allows both application codes.
- Default configuration rejects every application code.
- An ordinary application code returns 401 with the rich error and
  `WWW-Authenticate` information.
- Non-OAuth2 requests are skipped.
- Schema and priority sanity checks pass.

## Files in Scope

- `src/apisix/plugins/bk-oauth2-appcode-validate.lua`
- `src/apisix/tests/test-bk-oauth2-appcode-validate.lua`
- `src/apisix/t/bk-oauth2-appcode-validate.t`
- `src/apisix/plugins/README.md`

No existing OAuth2 plugin will be modified.

## Verification

Run from `src/apisix` unless otherwise noted:

1. Focused Busted test for the new plugin.
2. `RUN_WITH_IT= make test-nginx CASE_FILE=bk-oauth2-appcode-validate.t`
3. `RUN_WITH_IT= make lint`
4. `RUN_WITH_IT= make test`
5. From the repository root, `make check-license`

All commands must pass on the final diff. Existing unrelated worktree changes
must remain unstaged and unmodified.
