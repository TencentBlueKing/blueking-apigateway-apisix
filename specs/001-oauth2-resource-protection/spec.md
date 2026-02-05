# Feature Specification: OAuth2 Resource Protection

**Feature Branch**: `001-oauth2-resource-protection`  
**Created**: 2026-02-03  
**Status**: Draft  
**Input**: User description: "I want to add plugins for oauth protected resource and the oauth2 access_token verify."

## Overview

This feature adds OAuth2 resource protection to the BlueKing API Gateway as an alternative to the existing `bk-auth-verify` and `bk-auth-validate` plugins. Users can choose between:
- **Legacy path**: `bk-auth-verify` → `bk-auth-validate` (existing BlueKing authentication)
- **OAuth2 path**: `bk-oauth2-protected-resource` → `bk-oauth2-verify` → `bk-auth-validate` → `bk-oauth2-audience-validate`

The OAuth2 path implements RFC-compliant OAuth2 protected resource functionality with BlueKing-specific audience validation.

### Plugin Architecture

Three new plugins will be added:

1. **bk-oauth2-protected-resource**: Detects OAuth2 vs legacy auth, returns WWW-Authenticate header for OAuth2 discovery
2. **bk-oauth2-verify**: Verifies OAuth2 access tokens via bkauth component
3. **bk-oauth2-audience-validate**: Validates audience claims for MCP servers and gateway APIs

### Context Flow

```
Request with Authorization: Bearer {token}
    ↓
bk-oauth2-protected-resource (sets ctx.var.is_bk_oauth2 = true)
    ↓
bk-oauth2-verify (verifies token, sets ctx.var.bk_app, bk_user, audience)
    ↓
bk-auth-validate (existing plugin, runs normally)
    ↓
bk-oauth2-audience-validate (validates audience against resource)
    ↓
Backend Service
```

```
Request with X-Bkapi-Authorization header (legacy)
    ↓
bk-oauth2-protected-resource (sets ctx.var.is_bk_oauth2 = false, skips)
    ↓
bk-auth-verify (existing legacy auth)
    ↓
bk-auth-validate (existing plugin)
    ↓
Backend Service
```

## User Scenarios & Testing *(mandatory)*

### User Story 1 - OAuth2 Protected Resource Detection (Priority: P1)

API consumers using OAuth2 authentication are guided through the OAuth2 discovery flow when accessing protected resources. The gateway detects whether a request uses OAuth2 (Authorization: Bearer) or legacy BlueKing auth (X-Bkapi-Authorization) and routes accordingly.

**Why this priority**: This is the entry point for all OAuth2 requests. Without proper detection and routing, no OAuth2 authentication can proceed. The WWW-Authenticate header enables OAuth2 agents to discover resource metadata.

**Independent Test**: Deploy a route with bk-oauth2-protected-resource enabled. Test: (1) request with Authorization: Bearer → proceeds with OAuth2 flow, (2) request with X-Bkapi-Authorization → skips to legacy flow, (3) request without any auth header → returns 401 with WWW-Authenticate header.

**Acceptance Scenarios**:

1. **Given** a route has bk-oauth2-protected-resource enabled, **When** a client sends a request with `X-Bkapi-Authorization` header, **Then** the plugin sets `ctx.var.is_bk_oauth2 = false` and skips further processing (allows legacy flow).

2. **Given** a route has bk-oauth2-protected-resource enabled, **When** a client sends a request with `Authorization: Bearer {token}` header, **Then** the plugin sets `ctx.var.is_bk_oauth2 = true` and allows the request to proceed to OAuth2 verification.

3. **Given** a route has bk-oauth2-protected-resource enabled, **When** a client sends a request without `Authorization: Bearer` or `X-Bkapi-Authorization` headers, **Then** the plugin returns 401 Unauthorized with header:
   ```
   WWW-Authenticate: Bearer resource_metadata="https://{bk-apigateway-host}/.well-known/oauth-protected-resource?resource={URL_ENCODED_PATH}"
   ```
   where `{bk-apigateway-host}` is from `bk-core/config.lua hosts.bk-apigateway-host` and `{URL_ENCODED_PATH}` is the URL-encoded current request path.

---

### User Story 2 - OAuth2 Token Verification (Priority: P1)

API consumers with valid OAuth2 access tokens are authenticated, and their identity (app, user, audience) is extracted and made available for downstream authorization checks.

**Why this priority**: Token verification is the core authentication step. Without it, no OAuth2 identity can be established. This works together with P1 (detection) as the foundation.

**Independent Test**: Deploy a route with both bk-oauth2-protected-resource and bk-oauth2-verify enabled. Send a request with a valid Bearer token → verify ctx.var.bk_app, bk_user, and audience are set correctly.

**Acceptance Scenarios**:

1. **Given** `ctx.var.is_bk_oauth2 == true`, **When** bk-oauth2-verify runs, **Then** it calls `bk-components/bkauth.lua verify_oauth2_access_token` to validate the token.

2. **Given** token verification succeeds with response `{"data": {"bk_app_code": "...", "bk_username": "...", "audience": [...]}}`, **When** bk-oauth2-verify processes the response, **Then** it:
   - Creates and sets `ctx.var.bk_app` (app object)
   - Creates and sets `ctx.var.bk_user` (user object)
   - Sets `ctx.var.bk_app_code`
   - Sets `ctx.var.audience` (array of audience strings)
   - Sets `ctx.var.auth_params_location = "header"`

3. **Given** `ctx.var.is_bk_oauth2 == false`, **When** bk-oauth2-verify is in the plugin chain, **Then** it skips processing (does not run).

4. **Given** `ctx.var.is_bk_oauth2 == true`, **When** token verification fails (invalid/expired token), **Then** bk-oauth2-verify returns 401 Unauthorized with appropriate error message.

5. **Given** `ctx.var.is_bk_oauth2 == true`, **When** bk-auth-verify is in the plugin chain, **Then** bk-auth-verify skips processing (does not run for OAuth2 requests).

---

### User Story 3 - Audience Validation for MCP Servers (Priority: P2)

OAuth2 tokens with MCP server audience claims are validated to ensure the token is authorized for the specific MCP server being accessed.

**Why this priority**: Audience validation provides fine-grained authorization beyond token validity. MCP server validation is a specific use case that requires path parsing.

**Independent Test**: Deploy a route at `/prod/api/v2/mcp-servers/my-server/...` with audience validation enabled. Test with: (1) token with `mcp_server:my-server` audience → access granted, (2) token with different MCP server audience → access denied.

**Acceptance Scenarios**:

1. **Given** `ctx.var.is_bk_oauth2 == true` and `ctx.var.audience` contains `mcp_server:{mcp_server_name}`, **When** the request path matches `*/prod/api/v2/mcp-servers/{mcp_server_name}/*`, **Then** the plugin validates that the `{mcp_server_name}` from the path exists in the audience.

2. **Given** `ctx.var.is_bk_oauth2 == true` and `ctx.var.audience` contains an MCP server audience, **When** the current gateway is NOT `bk-apigateway`, **Then** the plugin returns 403 Forbidden (MCP server audiences only valid for bk-apigateway gateway).

3. **Given** `ctx.var.is_bk_oauth2 == true` and `ctx.var.audience` contains `mcp_server:server-a`, **When** the request path is for `mcp-servers/server-b/...`, **Then** the plugin returns 403 Forbidden (audience mismatch).

---

### User Story 4 - Audience Validation for Gateway APIs (Priority: P2)

OAuth2 tokens with gateway API audience claims are validated to ensure the token is authorized for the specific gateway and API resource being accessed.

**Why this priority**: Gateway API audience validation enables fine-grained authorization at the API level, complementing MCP server validation.

**Independent Test**: Deploy a route on gateway `my-gateway` with resource `my-api`. Test with: (1) token with `gateway:my-gateway/api:my-api` audience → access granted, (2) token with wildcard `gateway:my-gateway/api:*` → access granted, (3) token with different gateway → access denied.

**Acceptance Scenarios**:

1. **Given** `ctx.var.is_bk_oauth2 == true` and `ctx.var.audience` contains `gateway:{gateway_name}/api:{api_name}`, **When** `ctx.var.bk_gateway_name == {gateway_name}` AND `ctx.var.bk_resource_name == {api_name}`, **Then** access is granted.

2. **Given** `ctx.var.is_bk_oauth2 == true` and `ctx.var.audience` contains `gateway:{gateway_name}/api:*` (wildcard), **When** `ctx.var.bk_gateway_name == {gateway_name}`, **Then** access is granted for any API under that gateway.

3. **Given** `ctx.var.is_bk_oauth2 == true` and `ctx.var.audience` contains gateway API audiences, **When** `ctx.var.bk_gateway_name` or `ctx.var.bk_resource_name` does NOT match any audience, **Then** the plugin returns 403 Forbidden.

4. **Given** `ctx.var.is_bk_oauth2 == true`, **When** `ctx.var.audience` is empty or nil, **Then** the plugin returns 403 Forbidden with reason "empty audience".

---

### Edge Cases

- What happens when a request has both `Authorization: Bearer` and `X-Bkapi-Authorization` headers? (Priority: X-Bkapi-Authorization takes precedence; sets is_bk_oauth2 = false)
- What happens when the Bearer token is malformed (not a valid token string)? (Return 401 in bk-oauth2-verify with "invalid token format")
- What happens when bkauth verification service is unreachable? (Return 503 Service Unavailable with error logged)
- What happens when audience contains both mcp_server and gateway_api types? (Both validations apply; at least one must match)
- What happens when the path doesn't match the expected MCP server pattern? (MCP server audience validation is skipped; gateway_api validation still applies if present)
- How does the plugin handle tokens with very large audience arrays? (Process all audiences; no practical limit but log warning if >100 entries)

## Requirements *(mandatory)*

### Functional Requirements

#### Plugin 1: bk-oauth2-protected-resource

- **FR-001**: Plugin MUST have priority 18740 (higher than `bk-access-token-source` at 18735) to run before token source detection.

- **FR-002**: Plugin MUST check for `X-Bkapi-Authorization` header first. If present, set `ctx.var.is_bk_oauth2 = false` and skip further processing (allow legacy flow).

- **FR-003**: Plugin MUST check for `Authorization: Bearer {token}` header. If present, set `ctx.var.is_bk_oauth2 = true` and allow request to proceed.

- **FR-004**: Plugin MUST return 401 Unauthorized with `WWW-Authenticate` header when neither auth header is present:
  ```
  WWW-Authenticate: Bearer resource_metadata="https://{host}/.well-known/oauth-protected-resource?resource={path}"
  ```
  where `{host}` is from `bk-core/config.lua hosts.bk-apigateway-host` and `{path}` is URL-encoded request path.

#### Plugin 2: bk-oauth2-verify

- **FR-005**: Plugin MUST have priority 18732 (higher than `bk-auth-verify` at 18730) to run before legacy verification.

- **FR-006**: Plugin MUST only run when `ctx.var.is_bk_oauth2 == true`; skip otherwise.

- **FR-007**: Existing `bk-auth-verify` plugin MUST be modified to check `ctx.var.is_bk_oauth2` at start and skip processing if true (allows OAuth2 flow to handle authentication).

- **FR-008**: Plugin MUST call `bk-components/bkauth.lua verify_oauth2_access_token` to verify the OAuth2 access token.

- **FR-009**: Plugin MUST add caching support via `bk-cache/oauth2-access-token.lua` for verified tokens with a TTL of 300 seconds (5 minutes).

- **FR-010**: On successful verification, plugin MUST set context variables:
  - `ctx.var.bk_app` (app object created from response)
  - `ctx.var.bk_user` (user object created from response)
  - `ctx.var.bk_app_code` (from response data)
  - `ctx.var.audience` (array from response data)
  - `ctx.var.auth_params_location = "header"`

#### Plugin 3: bk-oauth2-audience-validate

- **FR-011**: Plugin MUST have priority 17678 (lower than `bk-auth-validate` at 17680) to run after general validation.

- **FR-012**: Plugin MUST only run when `ctx.var.is_bk_oauth2 == true`; skip otherwise.

- **FR-013**: Plugin MUST return 403 Forbidden if `ctx.var.audience` is empty or nil (token valid but lacks required permissions).

- **FR-014**: Plugin MUST parse audience strings in two formats:
  - `mcp_server:{mcp_server_name}` → type "mcp_server", value "{mcp_server_name}"
  - `gateway:{gateway_name}/api:{api_name}` → type "gateway_api", gateway "{gateway_name}", api "{api_name}"
  - `gateway:{gateway_name}/api:*` → type "gateway_api" with wildcard for all APIs

- **FR-015**: For `mcp_server` type audience:
  - Current gateway MUST be `bk-apigateway`
  - Request path MUST match pattern `*/prod/api/v2/mcp-servers/{mcp_server_name}/*`
  - Parsed `{mcp_server_name}` from path MUST exist in audience

- **FR-016**: For `gateway_api` type audience:
  - If wildcard `gateway:{name}/api:*` present, `ctx.var.bk_gateway_name` MUST match `{name}`
  - Otherwise, `ctx.var.bk_gateway_name` AND `ctx.var.bk_resource_name` MUST match an audience entry

- **FR-017**: Plugin MUST return 403 Forbidden with specific reason when audience validation fails (e.g., "audience mismatch", "mcp_server not in audience", "gateway/api not authorized").

### Key Entities

- **OAuth2 Access Token**: Bearer token provided in Authorization header, verified via bkauth service. Contains identity (app, user) and audience claims.

- **Audience Claim**: Array of strings specifying which resources the token is authorized to access. Two formats:
  - `mcp_server:{name}` - Access to specific MCP server
  - `gateway:{gateway}/api:{api}` - Access to specific gateway API (or wildcard `api:*`)

- **Context Variables**: Request-scoped variables used for cross-plugin communication:
  - `is_bk_oauth2` (boolean) - Whether request uses OAuth2 auth
  - `bk_app` (object) - Authenticated application
  - `bk_user` (object) - Authenticated user
  - `bk_app_code` (string) - Application code
  - `audience` (array) - Audience claims from token
  - `auth_params_location` (string) - Where auth params were found ("header")

- **bkauth Verification Response**: Response from bkauth OAuth2 token verification:
  ```json
  {"data": {"bk_app_code": "...", "bk_username": "...", "audience": ["..."]}}
  ```

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Gateway correctly routes 100% of requests with `X-Bkapi-Authorization` to legacy auth flow (is_bk_oauth2 = false).

- **SC-002**: Gateway correctly routes 100% of requests with `Authorization: Bearer` to OAuth2 flow (is_bk_oauth2 = true).

- **SC-003**: OAuth2 token verification adds less than 10 milliseconds of latency for cached tokens under normal load (1000 req/s).

- **SC-004**: Gateway returns correct WWW-Authenticate header for 100% of unauthenticated requests with resource_metadata URL.

- **SC-005**: Audience validation correctly enforces MCP server access for 100% of mcp_server audience types.

- **SC-006**: Audience validation correctly enforces gateway API access for 100% of gateway_api audience types (including wildcards).

- **SC-007**: Error messages clearly indicate the reason for authentication/authorization failure (empty audience, audience mismatch, invalid token, etc.).

## Assumptions

- The bkauth service is available and provides `verify_oauth2_access_token` API.
- The `hosts.bk-apigateway-host` configuration exists in `bk-core/config.lua`.
- Existing `bk-auth-verify` and `bk-auth-validate` plugins will be modified to check `ctx.var.is_bk_oauth2` and skip when true.
- The MCP server path pattern `*/prod/api/v2/mcp-servers/{mcp_server_name}/*` is fixed and well-known.
- Token caching via `bk-cache/oauth2-access-token.lua` follows existing caching patterns.
- Standard Bearer token format is used: "Authorization: Bearer {token}".

## Clarifications

### Session 2026-02-03

- Q: How should bk-auth-verify be prevented from running for OAuth2 requests? → A: Modify bk-auth-verify to check `ctx.var.is_bk_oauth2` at start and skip if true
- Q: What TTL should be used for cached OAuth2 token verification results? → A: 300 seconds (5 minutes)
- Q: What HTTP status code should audience validation failures return? → A: 403 Forbidden (RFC-compliant, distinguishes authentication vs authorization failures)
- Q: What specific priority numbers for the 3 plugins? → A: bk-oauth2-protected-resource: 18740, bk-oauth2-verify: 18732, bk-oauth2-audience-validate: 17678
