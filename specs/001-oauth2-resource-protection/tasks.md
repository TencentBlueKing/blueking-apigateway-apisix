# Tasks: OAuth2 Resource Protection

**Input**: Design documents from `/specs/001-oauth2-resource-protection/`
**Prerequisites**: plan.md (required), spec.md (required for user stories)

**Tests**: Tests ARE REQUIRED per constitution (TDD is NON-NEGOTIABLE). Write tests first, ensure they fail, then implement.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Plugins**: `src/apisix/plugins/`
- **Unit tests**: `src/apisix/tests/`
- **Functional tests**: `src/apisix/t/`
- **Cache modules**: `src/apisix/plugins/bk-cache/`
- **Components**: `src/apisix/plugins/bk-components/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Verify development environment and existing patterns

- [x] T001 Verify development environment by running `make test` to confirm existing tests pass
- [x] T002 Review existing bk-auth-verify.lua plugin pattern in src/apisix/plugins/bk-auth-verify.lua
- [x] T003 [P] Review existing bk-cache/access-token.lua caching pattern in src/apisix/plugins/bk-cache/access-token.lua
- [x] T004 [P] Review existing bk-components/bkauth.lua API pattern in src/apisix/plugins/bk-components/bkauth.lua

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T005 Add `get_bk_apigateway_host()` function to src/apisix/plugins/bk-core/config.lua to return `hosts.bk-apigateway-host` configuration value
- [x] T006 Add `verify_oauth2_access_token(access_token)` function to src/apisix/plugins/bk-components/bkauth.lua following existing `verify_app_secret` pattern, calling POST /api/v1/oauth2/access-tokens/verify with response `{"data": {"bk_app_code": "...", "bk_username": "...", "audience": [...]}}`
- [x] T007 Create OAuth2 access token cache module at src/apisix/plugins/bk-cache/oauth2-access-token.lua with 300 second TTL and fallback cache following existing access-token.lua pattern

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - OAuth2 Protected Resource Detection (Priority: P1) 🎯 MVP

**Goal**: Detect OAuth2 vs legacy auth and return WWW-Authenticate header for discovery

**Independent Test**: Deploy route with bk-oauth2-protected-resource enabled. Test: (1) request with Authorization: Bearer → proceeds with OAuth2 flow, (2) request with X-Bkapi-Authorization → skips to legacy flow, (3) request without any auth header → returns 401 with WWW-Authenticate header.

### Tests for User Story 1 (TDD - Write First, Must Fail)

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T008 [P] [US1] Create busted unit test file at src/apisix/tests/test-bk-oauth2-protected-resource.lua with test cases: (1) X-Bkapi-Authorization header sets is_bk_oauth2=false, (2) Authorization Bearer header sets is_bk_oauth2=true, (3) no auth header returns 401 with WWW-Authenticate, (4) both headers present prioritizes X-Bkapi-Authorization
- [x] T009 [P] [US1] Create test-nginx functional test file at src/apisix/t/bk-oauth2-protected-resource.t with HTTP request/response tests for all acceptance scenarios

### Implementation for User Story 1

- [x] T010 [US1] Create plugin file src/apisix/plugins/bk-oauth2-protected-resource.lua with priority 18740, schema definition, check_schema function, and module exports
- [x] T011 [US1] Implement rewrite phase in bk-oauth2-protected-resource.lua: check X-Bkapi-Authorization header first, if present set ctx.var.is_bk_oauth2 = false and return
- [x] T012 [US1] Implement Authorization Bearer detection in bk-oauth2-protected-resource.lua: if "Authorization: Bearer {token}" present, set ctx.var.is_bk_oauth2 = true and return
- [x] T013 [US1] Implement WWW-Authenticate response in bk-oauth2-protected-resource.lua: when no auth headers, return 401 with header `WWW-Authenticate: Bearer resource_metadata="https://{host}/.well-known/oauth-protected-resource?resource={path}"` using bk-core.config.get_bk_apigateway_host() and URL-encoded request path
- [x] T014 [US1] Add error handling using bk-core.errorx for 401 responses in bk-oauth2-protected-resource.lua
- [x] T015 [US1] Export private functions for testing via `if _TEST then` block in bk-oauth2-protected-resource.lua
- [x] T016 [US1] Run `make test-busted` to verify unit tests pass for bk-oauth2-protected-resource
- [x] T017 [US1] Run `make test-nginx CASE_FILE=bk-oauth2-protected-resource.t` to verify functional tests pass

**Checkpoint**: User Story 1 complete - OAuth2 detection works independently

---

## Phase 4: User Story 2 - OAuth2 Token Verification (Priority: P1)

**Goal**: Verify OAuth2 access tokens via bkauth and set context variables

**Independent Test**: Deploy route with bk-oauth2-protected-resource and bk-oauth2-verify enabled. Send request with valid Bearer token → verify ctx.var.bk_app, bk_user, and audience are set correctly.

### Tests for User Story 2 (TDD - Write First, Must Fail)

- [x] T018 [P] [US2] Create busted unit test file at src/apisix/tests/test-bk-oauth2-verify.lua with test cases: (1) skips when is_bk_oauth2=false, (2) calls bkauth.verify_oauth2_access_token with token, (3) sets ctx.var.bk_app/bk_user/bk_app_code/audience on success, (4) returns 401 on verification failure, (5) uses cache for repeated tokens
- [x] T019 [P] [US2] Create test-nginx functional test file at src/apisix/t/bk-oauth2-verify.t with HTTP tests for token verification flow

### Implementation for User Story 2

- [x] T020 [US2] Create plugin file src/apisix/plugins/bk-oauth2-verify.lua with priority 18732, schema definition, check_schema function, and module exports
- [x] T021 [US2] Implement is_bk_oauth2 check in bk-oauth2-verify.lua: at start of rewrite phase, if ctx.var.is_bk_oauth2 ~= true then return (skip processing)
- [x] T022 [US2] Implement Bearer token extraction in bk-oauth2-verify.lua: parse "Authorization: Bearer {token}" header and extract token string
- [x] T023 [US2] Implement token verification in bk-oauth2-verify.lua: call bk-cache/oauth2-access-token.lua get_oauth2_access_token(token) which calls bkauth.verify_oauth2_access_token
- [x] T024 [US2] Implement context variable setting in bk-oauth2-verify.lua on successful verification: create bk_app using bk-define.app, create bk_user using bk-define.user, set ctx.var.bk_app, ctx.var.bk_user, ctx.var.bk_app_code, ctx.var.audience, ctx.var.auth_params_location="header"
- [x] T025 [US2] Implement error handling in bk-oauth2-verify.lua: return 401 via errorx.exit_with_apigw_err on verification failure with appropriate error message
- [x] T026 [US2] Export private functions for testing via `if _TEST then` block in bk-oauth2-verify.lua
- [x] T027 [US2] Run `make test-busted` to verify unit tests pass for bk-oauth2-verify
- [x] T028 [US2] Run `make test-nginx CASE_FILE=bk-oauth2-verify.t` to verify functional tests pass

**Checkpoint**: User Story 2 complete - OAuth2 token verification works independently

---

## Phase 5: Modify bk-auth-verify for OAuth2 Compatibility

**Purpose**: Ensure legacy bk-auth-verify skips when OAuth2 flow is active

- [x] T029 Modify src/apisix/plugins/bk-auth-verify.lua: add check at start of rewrite function `if ctx.var.is_bk_oauth2 == true then return end` to skip processing for OAuth2 requests
- [x] T030 Update existing tests in src/apisix/tests/test-bk-auth-verify.lua to add test case verifying skip behavior when is_bk_oauth2=true
- [x] T031 Run `make test-busted` to verify all bk-auth-verify tests still pass

**Checkpoint**: Legacy auth flow properly skips for OAuth2 requests

---

## Phase 6: User Story 3 & 4 - Audience Validation (Priority: P2)

**Goal**: Validate audience claims for MCP servers and gateway APIs

**Independent Test**: 
- US3: Deploy route at `/prod/api/v2/mcp-servers/my-server/...` with audience validation. Test with mcp_server:my-server audience → access granted, different MCP server → access denied.
- US4: Deploy route on gateway `my-gateway` with resource `my-api`. Test with gateway:my-gateway/api:my-api → granted, wildcard gateway:my-gateway/api:* → granted, different gateway → denied.

### Tests for User Story 3 & 4 (TDD - Write First, Must Fail)

- [x] T032 [P] [US3] Create busted unit test file at src/apisix/tests/test-bk-oauth2-audience-validate.lua with test cases for MCP server validation: (1) skips when is_bk_oauth2=false, (2) returns 403 when audience is empty, (3) parses mcp_server:{name} format correctly, (4) validates gateway is bk-apigateway for mcp_server audiences, (5) extracts mcp_server_name from path pattern, (6) returns 403 on mcp_server mismatch
- [x] T033 [P] [US4] Add test cases to src/apisix/tests/test-bk-oauth2-audience-validate.lua for gateway API validation: (1) parses gateway:{gw}/api:{api} format, (2) matches ctx.var.bk_gateway_name and bk_resource_name, (3) handles wildcard api:* correctly, (4) returns 403 on gateway/api mismatch
- [x] T034 [P] [US3] Create test-nginx functional test file at src/apisix/t/bk-oauth2-audience-validate.t with HTTP tests for MCP server and gateway API audience validation

### Implementation for User Story 3 & 4

- [x] T035 [US3] Create plugin file src/apisix/plugins/bk-oauth2-audience-validate.lua with priority 17678, schema definition, check_schema function, and module exports
- [x] T036 [US3] Implement is_bk_oauth2 check in bk-oauth2-audience-validate.lua: at start of rewrite phase, if ctx.var.is_bk_oauth2 ~= true then return (skip processing)
- [x] T037 [US3] Implement empty audience check in bk-oauth2-audience-validate.lua: if ctx.var.audience is nil or empty, return 403 Forbidden with reason "empty audience"
- [x] T038 [US3] Implement audience parsing functions in bk-oauth2-audience-validate.lua: parse_audience(audience_string) returns {type="mcp_server", name="..."} or {type="gateway_api", gateway="...", api="..."}
- [x] T039 [US3] Implement MCP server path parsing in bk-oauth2-audience-validate.lua: extract mcp_server_name from path pattern `*/prod/api/v2/mcp-servers/{mcp_server_name}/*` using ngx.re.match
- [x] T040 [US3] Implement MCP server validation in bk-oauth2-audience-validate.lua: check gateway is "bk-apigateway", parse mcp_server_name from path, verify it exists in audience with mcp_server type
- [x] T041 [US4] Implement gateway API validation in bk-oauth2-audience-validate.lua: for gateway_api audiences, check if ctx.var.bk_gateway_name matches gateway and (api is "*" OR ctx.var.bk_resource_name matches api)
- [x] T042 [US3] Implement validation logic in bk-oauth2-audience-validate.lua: iterate through all parsed audiences, if any matches return (allow), if none match return 403 with specific reason
- [x] T043 [US3] Add error handling using bk-core.errorx for 403 responses with reasons: "empty audience", "mcp_server not in audience", "gateway/api not authorized"
- [x] T044 [US3] Export private functions for testing via `if _TEST then` block in bk-oauth2-audience-validate.lua
- [x] T045 [US3] Run `make test-busted` to verify unit tests pass for bk-oauth2-audience-validate
- [x] T046 [US3] Run `make test-nginx CASE_FILE=bk-oauth2-audience-validate.t` to verify functional tests pass

**Checkpoint**: User Stories 3 & 4 complete - Audience validation works for MCP servers and gateway APIs

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, integration testing, and final validation

- [x] T047 Update src/apisix/plugins/README.md to add entries for bk-oauth2-protected-resource (priority: 18740), bk-oauth2-verify (priority: 18732), bk-oauth2-audience-validate (priority: 17678) with descriptions
- [x] T048 Run `make lint` to verify all new code passes luacheck
- [x] T049 Run `make check-license` to verify all new Lua files have TencentBlueKing MIT license headers
- [x] T050 Run `make test` to verify all unit tests and functional tests pass
- [x] T051 [P] Review all error messages for clarity and consistency with existing bk-* plugins
- [x] T052 [P] Verify performance: cached token verification should add <10ms latency

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies - can start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 - BLOCKS all user stories
- **Phase 3 (US1)**: Depends on Phase 2 - can start after foundational
- **Phase 4 (US2)**: Depends on Phase 2 - can run in parallel with Phase 3
- **Phase 5 (bk-auth-verify mod)**: Depends on Phase 3 & 4 completion
- **Phase 6 (US3 & US4)**: Depends on Phase 4 (needs bk-oauth2-verify for context variables)
- **Phase 7 (Polish)**: Depends on all phases complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P1)**: Can start after Foundational (Phase 2) - Can run in parallel with US1
- **User Story 3 (P2)**: Depends on US2 (needs ctx.var.audience to be set by bk-oauth2-verify)
- **User Story 4 (P2)**: Depends on US2 (needs ctx.var.audience) - Can run in parallel with US3

### Within Each User Story

- Tests MUST be written and FAIL before implementation (TDD per constitution)
- Plugin skeleton before logic implementation
- Core logic before error handling
- Export test functions last
- Verify tests pass before moving to next story

### Parallel Opportunities

```bash
# Phase 1: All review tasks can run in parallel
T002, T003, T004 can run in parallel

# Phase 2: Independent foundational tasks
T006, T007 can run in parallel (after T005)

# Phase 3 & 4: US1 and US2 tests can run in parallel
T008, T009, T018, T019 can all run in parallel

# Phase 6: All test creation tasks can run in parallel
T032, T033, T034 can run in parallel

# Phase 7: Review tasks can run in parallel
T051, T052 can run in parallel
```

---

## Implementation Strategy

### MVP First (User Stories 1 & 2 Only)

1. Complete Phase 1: Setup (T001-T004)
2. Complete Phase 2: Foundational (T005-T007)
3. Complete Phase 3: User Story 1 - OAuth2 Detection (T008-T017)
4. Complete Phase 4: User Story 2 - Token Verification (T018-T028)
5. Complete Phase 5: bk-auth-verify modification (T029-T031)
6. **STOP and VALIDATE**: Run `make test` - MVP is complete
7. Deploy/demo if ready - OAuth2 authentication now works

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently (detection works)
3. Add User Story 2 → Test independently (verification works) → MVP!
4. Add User Story 3 & 4 → Test independently (audience validation works)
5. Polish → Full feature complete

### Single Developer Strategy

Execute phases sequentially:
1. Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6 → Phase 7
2. Commit after each phase
3. Run `make test` after each user story phase

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests FAIL before implementing (TDD Red phase)
- Verify tests PASS after implementing (TDD Green phase)
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- All plugins use `bk-core.errorx` for error handling per constitution
- Follow existing plugin patterns (bk-auth-verify, bk-auth-validate) for code structure
