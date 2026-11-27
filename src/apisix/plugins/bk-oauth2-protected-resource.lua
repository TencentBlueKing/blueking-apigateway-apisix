--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
-- Licensed under the MIT License (the "License"); you may not use this file except
-- in compliance with the License. You may obtain a copy of the License at
--
--     http://opensource.org/licenses/MIT
--
-- Unless required by applicable law or agreed to in writing, software distributed under
-- the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
-- either express or implied. See the License for the specific language governing permissions and
-- limitations under the License.
--
-- We undertake not to change the open source license (MIT license) applicable
-- to the current version of the project delivered to anyone in the future.
--
-- # bk-oauth2-protected-resource
--
-- This plugin detects whether a request uses OAuth2 authentication (Authorization: Bearer)
-- or legacy BlueKing authentication (X-Bkapi-Authorization) and routes accordingly:
--
--     * X-Bkapi-Authorization present: legacy flow
--     * bkauth Bearer token (matched by the configured or default prefix rules):
--       OAuth2 flow; bkauth introspection checks the token
--     * otherwise, a non-bkauth Bearer is treated as no OAuth2 credential and kept as is:
--         - configured user ticket cookies on a user-only resource: legacy flow
--         - challenge_on_missing_credential=false (only the app channel is enabled): legacy flow
--         - allowed legacy credentials in the query string: legacy flow
--         - otherwise (default, personal/public enabled): 401 with
--           a WWW-Authenticate header containing the resource_metadata URL for OAuth2 discovery;
--           the error reason tells a missing Bearer apart from a non-bkauth Bearer
--
-- The selected branch is recorded in ctx.var.bk_auth_flow, returned by bk-auth-verify in the
-- X-Bkapi-Auth-Flow response header and available to loggers as $bk_auth_flow:
--
--     * oauth2: bkauth Bearer token, verified by bk-oauth2-verify
--     * legacy: X-Bkapi-Authorization present
--     * fallback_cookie: no OAuth2 credential, configured user ticket cookie
--     * fallback_no_credential: no OAuth2 credential, challenge_on_missing_credential=false
--     * fallback_query: no OAuth2 credential, legacy query credentials allowed and detected
--     * oauth2_challenge: no credential, 401 with WWW-Authenticate
--
-- This plugin depends on:
--     * bk-core.config: For hosts.bk-apigateway-host and bk_oauth2.bearer_token_rules configuration
--
local pl_types = require("pl.types")
local core = require("apisix.core")
local cookie = require("apisix.plugins.bk-core.cookie")
local oauth2 = require("apisix.plugins.bk-core.oauth2")
local errorx = require("apisix.plugins.bk-core.errorx")
local ngx = ngx
local ipairs = ipairs
local string_sub = string.sub
local string_lower = string.lower
local string_match = string.match

local plugin_name = "bk-oauth2-protected-resource"

local BKAPI_AUTHORIZATION_HEADER = "X-Bkapi-Authorization"
local AUTHORIZATION_HEADER = "Authorization"
local BEARER_PREFIX = "bearer "
local BEARER_PREFIX_LEN = #BEARER_PREFIX

local AUTH_FLOW_OAUTH2 = "oauth2"
local AUTH_FLOW_LEGACY = "legacy"
local AUTH_FLOW_FALLBACK_COOKIE = "fallback_cookie"
local AUTH_FLOW_FALLBACK_NO_CREDENTIAL = "fallback_no_credential"
local AUTH_FLOW_FALLBACK_QUERY = "fallback_query"
local AUTH_FLOW_OAUTH2_CHALLENGE = "oauth2_challenge"

local bearer_token_rules

local schema = {
    type = "object",
    properties = {
        -- return 401 with WWW-Authenticate when no credential is present;
        -- false hands such requests to the legacy flow (only the app channel is enabled)
        challenge_on_missing_credential = {
            type = "boolean",
            default = true,
        },
    },
}

local _M = {
    version = 0.1,
    priority = 18740,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.init()
    local rules, problems = oauth2.validate_bkauth_bearer_token_rules()
    bearer_token_rules = rules
    for _, problem in ipairs(problems) do
        core.log.error("bk-oauth2-protected-resource: invalid bk_gateway.bk_oauth2.", problem)
    end

    -- The gateway defaults to warn logging. Report the validated rules once per init.
    core.log.warn(plugin_name, ": effective bearer_token_rules (", #rules, "): ",
                  core.json.delay_encode(rules))
end


---Parse Bearer token from Authorization header (RFC 6750 case-insensitive)
---@param authorization string|nil The Authorization header value
---@return string|nil token The extracted token, or nil if not a Bearer token
local function parse_bearer_token(authorization)
    if pl_types.is_empty(authorization) then
        return nil
    end

    -- Case-insensitive check for "Bearer " prefix (RFC 6750)
    local auth_lower = string_lower(authorization)
    if string_sub(auth_lower, 1, BEARER_PREFIX_LEN) ~= BEARER_PREFIX then
        return nil
    end

    -- Extract token after prefix, trim leading whitespace
    local token = string_sub(authorization, BEARER_PREFIX_LEN + 1)
    token = string_match(token, "^%s*(%S.*)$")
    return token
end


local function has_configured_user_ticket_cookie(ctx)
    local resource_auth = ctx.var.bk_resource_auth
    local api_auth = ctx.var.bk_api_auth
    if not resource_auth or not resource_auth:get_verified_user_required()
        or resource_auth:get_verified_app_required() or not api_auth then
        return false
    end

    local user_conf = api_auth:get_user_conf()
    if not user_conf:is_empty() and user_conf.from_bk_token
        and not pl_types.is_empty(cookie.get_value("bk_token")) then
        return true
    end

    local rtx_conf = api_auth:get_rtx_conf()
    return not api_auth:is_user_type_uin() and not rtx_conf:is_empty() and rtx_conf.from_bk_ticket
        and not pl_types.is_empty(cookie.get_value("bk_ticket"))
end


local function has_legacy_query_credentials(ctx)
    local api_auth = ctx.var.bk_api_auth
    if not api_auth or not api_auth:allow_get_auth_params_from_parameters() then
        return false
    end

    local args = core.request.get_uri_args(ctx)
    return args.access_token ~= nil
        or args.bk_token ~= nil
        or args.bk_ticket ~= nil
        or ((args.bk_app_code ~= nil or args.app_code ~= nil)
            and (args.bk_app_secret ~= nil or args.app_secret ~= nil))
end


function _M.rewrite(conf, ctx)
    -- Check for X-Bkapi-Authorization header first (legacy BlueKing auth)
    -- If present, skip OAuth2 flow and allow legacy flow to handle authentication
    local bkapi_auth = core.request.header(ctx, BKAPI_AUTHORIZATION_HEADER)
    if not pl_types.is_empty(bkapi_auth) then
        ctx.var.is_bk_oauth2 = false
        ctx.var.bk_auth_flow = AUTH_FLOW_LEGACY
        core.log.info("bk-oauth2-protected-resource: X-Bkapi-Authorization present, using legacy auth")
        return
    end

    -- Check for Authorization: Bearer header (OAuth2), only bkauth tokens are intercepted
    local bearer_token = parse_bearer_token(core.request.header(ctx, AUTHORIZATION_HEADER))
    if bearer_token and oauth2.is_bkauth_bearer_token(bearer_token, bearer_token_rules) then
        -- OAuth2 flow: set flag for downstream plugins
        ctx.var.is_bk_oauth2 = true
        ctx.var.bk_auth_flow = AUTH_FLOW_OAUTH2
        core.log.info("bk-oauth2-protected-resource: bkauth Bearer detected, using OAuth2 flow")
        return
    end

    if bearer_token then
        core.log.info("bk-oauth2-protected-resource: non-bkauth Bearer, treated as no credential")
    end

    -- An absent, empty or unmatched Bearer leaves no OAuth2 credential.
    -- The legacy flow still verifies the cookie and resource requirements.
    if has_configured_user_ticket_cookie(ctx) then
        ctx.var.is_bk_oauth2 = false
        ctx.var.bk_auth_flow = AUTH_FLOW_FALLBACK_COOKIE
        core.log.info("bk-oauth2-protected-resource: user cookie detected, using legacy auth")
        return
    end

    -- Dashboard sets challenge_on_missing_credential = support_public or support_personal.
    -- Each flag requires user authentication on the resource and its client to be enabled.
    -- False means only the app channel is enabled. Hand the request to legacy auth,
    -- which can check credentials in the query string or request body.
    if conf.challenge_on_missing_credential == false then
        ctx.var.is_bk_oauth2 = false
        ctx.var.bk_auth_flow = AUTH_FLOW_FALLBACK_NO_CREDENTIAL
        core.log.info("bk-oauth2-protected-resource: no OAuth2 credential, using legacy auth")
        return
    end

    if has_legacy_query_credentials(ctx) then
        ctx.var.is_bk_oauth2 = false
        ctx.var.bk_auth_flow = AUTH_FLOW_FALLBACK_QUERY
        core.log.info("bk-oauth2-protected-resource: query credentials detected, using legacy auth")
        return
    end

    ctx.var.bk_auth_flow = AUTH_FLOW_OAUTH2_CHALLENGE
    core.log.info("bk-oauth2-protected-resource: no valid auth header, returning 401 with WWW-Authenticate")
    ngx.header["WWW-Authenticate"] = oauth2.build_www_authenticate_header(ctx)

    local reason = "no valid authentication header found"
    local expected = "Authorization: Bearer <token>"
    if bearer_token then
        reason = "the Bearer token is not a BlueKing OAuth2 token (prefix not matched)"
        expected = "Authorization: Bearer <BlueKing OAuth2 token>"
    end

    local err = errorx.new_general_unauthorized()
        :with_field("reason", reason)
        :with_field("expected", expected)
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._parse_bearer_token = parse_bearer_token
end

return _M
