# AGENTS.md


### Plugin Architecture

All BlueKing plugins follow the `bk-*` naming convention and execute in a specific priority order (17000-19000):

You can read the @plugins/README.md for more details

1. **Context Injection Phase (18800-19000)**: Inject request context
   - `bk-request-id`, `bk-stage-context`, `bk-resource-context`, `bk-log-context`, etc.

2. **Authentication Phase (18700-18800)**: Verify access tokens and users
   - `bk-access-token-source`, `bk-auth-verify`, `bk-username-required`

3. **Authorization/Rate Limiting Phase (17600-17700)**: Apply security policies
   - `bk-auth-validate`, `bk-jwt`, `bk-ip-restriction`, `bk-permission`, rate limiters

4. **Proxy Pre-processing Phase (17000-17500)**: Transform requests before proxying
   - `bk-delete-sensitive`, `bk-proxy-rewrite`, `bk-mock`

5. **Response Post-processing Phase (0-200)**: Handle responses
   - `bk-response-check`, `bk-debug`, `bk-error-wrapper`

### Shared Components (bk-core)

The `plugins/bk-core/` directory contains shared utilities:
- `errorx.lua`: Standardized error handling and response formatting
- `config.lua`: Configuration management
- `request.lua`: Request utilities
- `upstream.lua`: Upstream handling
- Other utilities: `cookie.lua`, `hmac.lua`, `url.lua`, `string.lua`

### Error Handling Pattern

All plugins use the standardized error handling from `bk-core.errorx`:

```lua
local errorx = require("apisix.plugins.bk-core.errorx")

-- Generate error
local err = errorx.new_user_verify_failed()
err = err:with_field("key", "value")

-- Exit with error
return errorx.exit_with_apigw_err(ctx, err, _M)
```

## Development Commands


### Testing

```bash
# Build test images (required first time, or when ci/Dockerfile.apisix-test-busted or ci/Dockerfile.apisix-test-nginx change)
make apisix-test-images

# Run all tests (busted unit tests + test-nginx functional tests)
make test

# Run only busted unit tests
make test-busted

# Run only test-nginx functional tests
make test-nginx

# Run specific test-nginx test case
make test-nginx CASE_FILE=bk-traffic-label.t
```

### Linting and Code Quality

```bash
# Run luacheck linter
make lint

# Check license headers on all Lua files
make check-license

# Pre-commit hooks run automatically on commit
# Manually run: pre-commit run --all-files
```

### Edition Management

The project supports multiple editions (TE/EE):

```bash
# Check current edition
make edition

# Switch to Enterprise Edition (EE)
make edition-ee

# Switch to Tencent Edition (TE)
make edition-te

# Reset to base edition
make edition-reset
```

## Plugin Development Guidelines

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

### Testing Patterns

**Busted Unit Tests** (`tests/test-bk-*.lua`):
- Use stubs to mock external dependencies
- Test private functions by exporting them with `if _TEST then`
- Clear/revert stubs in `after_each`
- Use assertions: `assert.is_nil(err)`, `assert.is_true(ok)`, `assert.is_equal(a, b)`

**Test-nginx** (`t/bk-*.t`):
- Functional/integration tests that simulate real HTTP requests
- Test full request/response flow through APISIX
- Reference: https://openresty.gitbooks.io/programming-openresty/content/testing/index.html

## License

All new Lua files must include the TencentBlueKing MIT license header. The `make check-license` command verifies this.

## Important Notes

- Custom plugins should NOT modify APISIX core directly; use patches in `src/build/patches/`
- Plugin priority determines execution order - consult `src/apisix/plugins/README.md` before setting
- Context injection plugins must NOT terminate requests (return early)
- All plugins should use `bk-core.errorx` for error handling to ensure consistent error responses
- The `bk-error-wrapper` plugin (priority: 0) wraps all errors in a standard format, so it runs last
