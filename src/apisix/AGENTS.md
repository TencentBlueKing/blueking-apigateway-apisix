# AGENTS.md

## Scope

This guide applies to `src/apisix/`, the BlueKing APISIX data-plane plugin
tree. The repository root `AGENTS.md` is the project map; for normal plugin
work, use this file as the closer instruction source.

Do not edit `../apisix-core/` for BlueKing plugin work unless the task is
explicitly about APISIX upstream behavior. APISIX source is a submodule used
for reference. Local APISIX patches live under `../build/patches/`.

## Project Layout

- `plugins/`: BlueKing APISIX plugins and shared Lua modules.
- `plugins/bk-core/`: common helpers such as `errorx`, `config`, `request`,
  `upstream`, `oauth2`, `proxy_phases`, `url`, and string helpers.
- `plugins/bk-components/`: clients for BlueKing services such as bkauth,
  bklogin, bkuser, ssm, and bk-apigateway-core.
- `plugins/bk-cache/` and `plugins/bk-cache-fallback/`: lrucache-backed
  auth, tenant, JWT, OAuth2, and fallback cache helpers.
- `plugins/bk-define/`: small domain objects for apps, users, access tokens,
  and context data.
- `tests/`: Busted unit tests. Top-level plugin tests use
  `tests/test-bk-*.lua`; helper module tests live in subdirectories such as
  `tests/bk-auth-verify/test-*.lua`.
- `t/`: test-nginx functional tests. Cases are named `t/bk-*.t`.
- `ci/`: Dockerfiles and scripts used by `make test-busted` and
  `make test-nginx`.
- `editions/`: edition-specific source files linked into this tree by
  `editionctl`.

## Setup

From the repository root, install the Python dependency that provides
`editionctl`:

```bash
python -m pip install -r src/apisix/requirements.txt
```

Build the Docker test images before running lint or tests for the first time,
or after changing `ci/Dockerfile.apisix-test-*` or `ci/run-test-*.sh`:

```bash
cd src/apisix
make apisix-test-images
```

The GitHub Actions workflow for APISIX uses Python `3.10.16`, installs
`src/apisix/requirements.txt`, switches to EE with `make edition-ee`, then runs
`make lint RUN_WITH_IT=""` and `make test RUN_WITH_IT=""` from `src/apisix`.

## Common Commands

Run these from `src/apisix` unless noted.

```bash
# Show or switch edition
make edition
make edition-ee
make edition-te
make edition-reset

# Build test images
make apisix-test-images

# Lint plugins with luacheck
make lint

# Run all APISIX tests
make test

# Run only Busted unit tests
make test-busted

# Run only test-nginx cases
make test-nginx

# Run one test-nginx case; the runner also runs t/bk-00.t
make test-nginx CASE_FILE=bk-traffic-label.t
```

In non-TTY environments, clear `RUN_WITH_IT`:

```bash
RUN_WITH_IT= make lint
RUN_WITH_IT= make test
```

The license check is a repository-root target, not a `src/apisix` target:

```bash
cd ../..
make check-license
```

## Edition Workflow

`editionctl.toml` defines `TE` and `EE`. `edition-metadata.json` records the
currently linked edition and the external files controlled by that edition. CI
switches to EE before lint and tests.

When touching an edition-controlled file, edit the source under
`editions/<edition>/...` first, then relink and test from `src/apisix`:

```bash
make edition-reset
make edition-ee
make test
```

Check that the target edition directory exists in the current checkout before
assuming TE or EE files are available.

## Plugin Architecture

BlueKing plugins normally use the `bk-*` naming convention, but priority values
are not limited to one range. The source of truth is the `priority` field in
each plugin module. Keep `plugins/README.md` in sync when adding a plugin or
changing a priority.

Current priority bands:

- Context and compatibility: high `188xx` priorities, including request,
  stage, backend, resource, real-IP, and log context plugins.
- Authentication and OAuth2: `187xx` priorities, including
  `bk-oauth2-protected-resource`, `bk-access-token-source`,
  `bk-oauth2-verify`, `bk-auth-verify`, and `bk-username-required`.
- Request validation, tenant checks, authorization, and rate limiting:
  `176xx` to `179xx` priorities.
- Proxy preprocessing: `174xx` priorities, including traffic labels,
  sensitive data removal, tenant defaults, and header or proxy rewrite plugins.
- Response, logging, and wrappers: lower priorities such as `399`, `153`,
  `145`, and `0`. `bk-error-wrapper` runs at priority `0`.

Before adding an early return to a high-priority context plugin, verify the
priority contract in `plugins/README.md` and nearby plugins. Some handlers are
special purpose, but context setup is usually expected to prepare `ctx.var` for
later plugins.

## Auth and Context Contracts

- Use `bk-core.errorx` for user-facing APIGW errors:

  ```lua
  local errorx = require("apisix.plugins.bk-core.errorx")

  local err = errorx.new_user_verify_failed()
  err = err:with_field("key", "value")

  return errorx.exit_with_apigw_err(ctx, err, _M)
  ```

- `bk-auth-verify` chooses verifiers in this order: `jwt`, then
  `access_token`, then `inner_jwt`. Preserve that order unless the task
  explicitly changes the auth contract and includes focused tests.
- OAuth2 flow depends on `ctx.var.is_bk_oauth2` and `ctx.var.audience` across
  `bk-oauth2-protected-resource`, `bk-oauth2-verify`, and
  `bk-oauth2-audience-validate`.
- MCP virtual app codes use `v_mcp_{mcp_service_id}_{app_code}`. Use
  `bk_app:get_real_app_code()` when downstream services expect the real app
  code, such as tenant lookup or signing JWTs.
- Do not log raw tokens or secrets. Follow existing masking patterns such as
  the OAuth2 token hint logs.

## Lua Style

Follow the existing Lua style in nearby files:

- 4-space indentation, no semicolons, and 100-column-ish lines.
- `snake_case` for variables and functions; `UPPER_CASE` for constants.
- Localize globals and requires near the top:

  ```lua
  local ngx = ngx
  local require = require
  local core = require("apisix.core")
  ```

- Prefer early returns and simple `<value>, err` returns for helpers.
- Return string error messages from internal helpers:

  ```lua
  local result, err = func()
  if not result then
      return nil, "failed to call func(): " .. err
  end
  ```

- Export private helpers only under `_TEST`:

  ```lua
  if _TEST then
      _M._private_function = private_function
  end
  ```

- `src/apisix/.luacheckrc` uses `std = "bkgw+ngx_lua"`, permits `_TEST`, and
  sets `unused_args = false`.

Notes:
- Run tests from `src/apisix` (the repo root does not have `make test`).
- In non-TTY environments, use `RUN_WITH_IT= make test`.

## Plugin Development Guidelines

- You can read the other plugins source code and test code to help you write the new plugin and test code.

### Plugin Isolation

- New plugins MUST define their own schema and `check_schema` function inline. Do NOT import or depend on another plugin's schema, functions, or module.
- Each plugin should be as self-contained as possible. Shared utilities from `bk-core/` are acceptable, but cross-plugin dependencies are not.

### Naming Conventions

- Plugin file: `src/apisix/plugins/bk-{name}.lua`
- Busted unit test: `src/apisix/tests/test-bk-{name}.lua`
- Test-nginx file: `src/apisix/t/bk-{name}.t`
- Update `src/apisix/plugins/README.md` with plugin priority and description

### Code Style (from Cursor rules)

1. **Indentation**: 4 spaces
2. **Spacing**: Spaces around operators (`local i = 1`)
3. **No semicolons**
4. **Two blank lines** between functions
5. **One blank line** between elseif branches
6. **Max line length**: 100 characters
7. **Variable naming**: `snake_case` (constants: `UPPER_CASE`)
8. **Function naming**: `snake_case`
9. **Return early** from functions
10. **Return pattern**: `<boolean>, err` (success flag, error message)

### Required Patterns

```lua
-- Localize all requires and ngx at the top
local ngx = ngx
local require = require
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")

-- Pre-allocate tables
local new_tab = require("table.new")
local t = new_tab(100, 0)

-- Error handling (check for nil/falsy, then return error string)
local result, err = func()
if not result then
    return nil, "failed to call func(): " .. err
end

-- Export private functions for testing
if _TEST then
    _M._private_function = private_function
end
```

Busted unit tests:

- Add or update Busted tests for plugin helper logic and branchy auth/cache
  behavior.
- `tests/busted_helper.lua` sets `_TEST = true`, defines helpers such as
  `CTX`, `RANDSTR`, `RANDINT`, and clears `busted_resty` state after each test.
- Revert or clear stubs in `after_each`.
- Common assertions include `assert.is_nil(err)`, `assert.is_true(ok)`,
  `assert.is_false(ok)`, `assert.is_equal(a, b)`, and
  `assert.stub(s).was_called_with(...)`.

test-nginx functional tests:

- Use `t/bk-*.t` for request/response flow through APISIX.
- `ci/run-test-nginx.sh` starts etcd, copies `plugins/` and `t/` into the
  APISIX test runtime, registers `bk-*.lua` plugins, injects `bk_gateway`
  config, and runs `prove`.
- `make test-nginx CASE_FILE=name.t` runs `t/bk-00.t` plus the named case.

For plugin changes, prefer a focused Busted test first. Add a test-nginx case
when behavior depends on APISIX request phases, routing, headers, response
filters, or log-phase behavior.

## Verification Before Handoff

- Markdown-only changes can skip `make lint` and `make test`; verify the diff
  instead.
- Lua or test changes should pass, from `src/apisix`:

  ```bash
  RUN_WITH_IT= make lint
  RUN_WITH_IT= make test
  ```

- If you add a new Lua file, also run the root license check:

  ```bash
  cd ../..
  make check-license
  ```

- If test images are missing or stale, run `make apisix-test-images` before
  lint/test. If Docker or the images are unavailable, report that explicitly
  instead of claiming the checks passed.

## PR Notes

The repository PR template expects a description, related issue or context,
code style check, unit tests, passing tests, and local integration validation
when applicable. Keep PRs narrow: plugin behavior, edition source files,
README/priority docs, and tests should stay in sync with the specific change.
