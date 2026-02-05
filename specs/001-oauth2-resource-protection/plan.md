# Implementation Plan: OAuth2 Resource Protection

**Branch**: `001-oauth2-resource-protection` | **Date**: 2026-02-03 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-oauth2-resource-protection/spec.md`

## Summary

Add three APISIX plugins to support OAuth2 resource protection as an alternative to the existing `bk-auth-verify`/`bk-auth-validate` flow. The plugins implement:
1. **bk-oauth2-protected-resource** (priority: 18740): Detection and routing between OAuth2 and legacy auth
2. **bk-oauth2-verify** (priority: 18732): Token verification via bkauth service
3. **bk-oauth2-audience-validate** (priority: 17678): Fine-grained audience-based authorization

The implementation follows existing BlueKing plugin patterns, uses `bk-core.errorx` for error handling, and integrates with the bkauth component for token verification.

## Technical Context

**Language/Version**: Lua 5.1 (LuaJIT 2.1) on OpenResty/APISIX  
**Primary Dependencies**: APISIX core, bk-core utilities, bk-components/bkauth.lua, bk-define modules  
**Storage**: LRU cache (in-memory) for OAuth2 token verification results  
**Testing**: Busted unit tests + test-nginx functional tests  
**Target Platform**: Linux (APISIX data plane)  
**Project Type**: APISIX plugin development  
**Performance Goals**: <10ms latency for cached tokens, <1ms p99 per plugin execution  
**Constraints**: Must integrate with existing bk-auth-verify/bk-auth-validate without breaking legacy flow  
**Scale/Scope**: 3 new plugins, 1 new cache module, 1 bkauth API addition, 1 existing plugin modification

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Plugin-First Architecture | ✅ PASS | 3 plugins with `bk-*` naming, priorities in valid ranges (17678, 18732, 18740) |
| II. Standardized Error Handling | ✅ PASS | Will use `bk-core.errorx` for all errors (401, 403 responses) |
| III. Test-First Development | ✅ PASS | Busted tests + test-nginx tests required per constitution |
| IV. Performance & Efficiency | ✅ PASS | Will use LRU cache (300s TTL), localized requires, early returns |
| V. Code Quality & Style | ✅ PASS | Will follow 4-space indent, snake_case, license headers, luacheck |

**Gate Result**: ✅ ALL PASSED - Proceed to implementation

## Project Structure

### Documentation (this feature)

```text
specs/001-oauth2-resource-protection/
├── plan.md              # This file
├── research.md          # Existing patterns analysis
├── data-model.md        # Context variables and entities
├── quickstart.md        # Testing guide
├── checklists/          # Quality checklists
│   └── requirements.md
└── tasks.md             # Task breakdown (created by /speckit.tasks)
```

### Source Code (repository root)

```text
src/apisix/
├── plugins/
│   ├── bk-oauth2-protected-resource.lua    # NEW: Priority 18740
│   ├── bk-oauth2-verify.lua                # NEW: Priority 18732
│   ├── bk-oauth2-audience-validate.lua     # NEW: Priority 17678
│   ├── bk-auth-verify.lua                  # MODIFY: Add is_bk_oauth2 check
│   ├── bk-cache/
│   │   └── oauth2-access-token.lua         # NEW: Token cache (300s TTL)
│   ├── bk-components/
│   │   └── bkauth.lua                      # MODIFY: Add verify_oauth2_access_token
│   ├── bk-core/
│   │   └── config.lua                      # READ: hosts.bk-apigateway-host
│   └── README.md                           # UPDATE: Add new plugin entries
├── tests/
│   ├── test-bk-oauth2-protected-resource.lua   # NEW
│   ├── test-bk-oauth2-verify.lua               # NEW
│   └── test-bk-oauth2-audience-validate.lua    # NEW
└── t/
    ├── bk-oauth2-protected-resource.t      # NEW
    ├── bk-oauth2-verify.t                  # NEW
    └── bk-oauth2-audience-validate.t       # NEW
```

**Structure Decision**: Following existing BlueKing plugin structure at `src/apisix/plugins/`. Each plugin has corresponding unit test in `tests/` and functional test in `t/`.

## Implementation Phases

### Phase 1: Plugin 1 - bk-oauth2-protected-resource (P1)

**Goal**: Detect OAuth2 vs legacy auth and return WWW-Authenticate header for discovery.

**Files to create**:
- `src/apisix/plugins/bk-oauth2-protected-resource.lua`
- `src/apisix/tests/test-bk-oauth2-protected-resource.lua`
- `src/apisix/t/bk-oauth2-protected-resource.t`

**Key implementation**:
```lua
-- Priority: 18740 (higher than bk-access-token-source at 18735)
-- Phase: rewrite

-- Logic:
-- 1. Check X-Bkapi-Authorization header → set ctx.var.is_bk_oauth2 = false, return
-- 2. Check Authorization: Bearer header → set ctx.var.is_bk_oauth2 = true, return
-- 3. Neither → return 401 with WWW-Authenticate header
```

**Dependencies**: `bk-core.config` (for hosts.bk-apigateway-host), `bk-core.errorx`

### Phase 2: Plugin 2 - bk-oauth2-verify (P1)

**Goal**: Verify OAuth2 tokens via bkauth and set context variables.

**Files to create/modify**:
- `src/apisix/plugins/bk-oauth2-verify.lua`
- `src/apisix/plugins/bk-cache/oauth2-access-token.lua`
- `src/apisix/plugins/bk-components/bkauth.lua` (add `verify_oauth2_access_token`)
- `src/apisix/tests/test-bk-oauth2-verify.lua`
- `src/apisix/t/bk-oauth2-verify.t`

**Key implementation**:
```lua
-- Priority: 18732 (higher than bk-auth-verify at 18730)
-- Phase: rewrite
-- Condition: Only run if ctx.var.is_bk_oauth2 == true

-- Logic:
-- 1. Extract Bearer token from Authorization header
-- 2. Call bk-cache/oauth2-access-token.lua (uses bkauth.verify_oauth2_access_token)
-- 3. On success: set ctx.var.bk_app, bk_user, bk_app_code, audience, auth_params_location
-- 4. On failure: return 401 via errorx
```

**Dependencies**: `bk-cache/oauth2-access-token.lua`, `bk-define.app`, `bk-define.user`, `bk-core.errorx`

### Phase 3: Modify bk-auth-verify

**Goal**: Skip processing when ctx.var.is_bk_oauth2 == true.

**File to modify**:
- `src/apisix/plugins/bk-auth-verify.lua`

**Change**:
```lua
function _M.rewrite(conf, ctx)
    -- NEW: Skip if OAuth2 flow is handling authentication
    if ctx.var.is_bk_oauth2 == true then
        return
    end
    
    -- Existing logic continues...
    local app, user = _M.verify(ctx)
    -- ...
end
```

### Phase 4: Plugin 3 - bk-oauth2-audience-validate (P2)

**Goal**: Validate audience claims for MCP servers and gateway APIs.

**Files to create**:
- `src/apisix/plugins/bk-oauth2-audience-validate.lua`
- `src/apisix/tests/test-bk-oauth2-audience-validate.lua`
- `src/apisix/t/bk-oauth2-audience-validate.t`

**Key implementation**:
```lua
-- Priority: 17678 (lower than bk-auth-validate at 17680)
-- Phase: rewrite
-- Condition: Only run if ctx.var.is_bk_oauth2 == true

-- Logic:
-- 1. Check ctx.var.audience is not empty → 403 if empty
-- 2. Parse audience formats: mcp_server:{name}, gateway:{gw}/api:{api}
-- 3. For mcp_server: validate gateway is bk-apigateway, parse path, check audience
-- 4. For gateway_api: match ctx.var.bk_gateway_name and bk_resource_name
-- 5. Return 403 if no audience matches
```

**Dependencies**: `bk-core.errorx`

### Phase 5: Documentation & Integration Testing

**Goal**: Update README and run full integration tests.

**Files to update**:
- `src/apisix/plugins/README.md` (add 3 new plugin entries with priorities)

**Validation**:
- `make test` (all unit + functional tests)
- `make lint` (luacheck)
- `make check-license`

## Complexity Tracking

No constitution violations requiring justification. All complexity is justified:

| Component | Complexity | Justification |
|-----------|------------|---------------|
| 3 separate plugins | Necessary | Matches existing bk-auth-verify/bk-auth-validate pattern; enables independent testing and clear priority ordering |
| New cache module | Necessary | Follows existing pattern in bk-cache/; enables 300s TTL for performance |
| bkauth modification | Minimal | Adding single new API function following existing pattern |

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Breaking legacy auth flow | is_bk_oauth2 flag ensures clear separation; legacy flow unchanged when flag is false |
| Performance regression | LRU cache with 300s TTL; localized requires; early returns |
| bkauth service unavailability | Follow existing fallback cache pattern from bk-cache/access-token.lua |
| Audience parsing edge cases | Comprehensive unit tests for all audience formats |

## Next Steps

1. Run `/speckit.tasks` to generate detailed task breakdown
2. Implement plugins following TDD (Red-Green-Refactor)
3. Run validation (`make test`, `make lint`, `make check-license`)
4. Update README.md with new plugin entries
5. Submit PR for review
