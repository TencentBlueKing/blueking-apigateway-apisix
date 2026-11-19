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
local core = require("apisix.core")
local config = require("apisix.plugins.bk-core.config")
local table_isarray = require("table.isarray")

local ngx = ngx
local ngx_escape_uri = ngx.escape_uri
local ngx_re_find = ngx.re.find
local ipairs = ipairs
local type = type
local string_match = string.match
local string_gsub = string.gsub
local string_format = string.format
local string_sub = string.sub
local string_len = string.len
local table_insert = table.insert

local _M = {
    APP_CHANNEL_DISABLED_REASON = "the OAuth2 app channel is not enabled for this route",
}


---Read bearer_token_rules; anything that is not a list (an empty list counts) is treated as not configured
local function get_bkauth_bearer_token_rules()
    local rules = config.get_oauth2_bearer_token_rules()
    if type(rules) ~= "table" or not table_isarray(rules) then
        return nil
    end
    return rules
end

-- app codes of the builtin OAuth2 clients; other app codes are real BlueKing apps
local BUILTIN_CLIENT_APP_CODES = {
    public = true,
    personal = true,
}


local function strip_subpath_prefix(path, gateway_name)
    local prefix = "/api/" .. gateway_name
    local prefix_len = string_len(prefix)
    if string_sub(path, 1, prefix_len) ~= prefix then
        return path
    end

    local next_char = string_sub(path, prefix_len + 1, prefix_len + 1)
    if next_char ~= "" and next_char ~= "/" then
        return path
    end

    path = string_sub(path, prefix_len + 1)
    if path == "" then
        path = "/"
    end
    return path
end


local function escape_auth_header_value(value)
    if value == nil or value == "" then
        return ""
    end

    local escaped = string_gsub(value, "\\", "\\\\")
    escaped = string_gsub(escaped, '"', '\\"')
    return escaped
end

---Build the WWW-Authenticate header value for OAuth2 discovery
---@param ctx table The current context object
---@param error_code string|nil The OAuth2 error code (e.g., "invalid_token", "invalid_request")
---@param error_description string|nil The human-readable error description
---@return string The WWW-Authenticate header value
function _M.build_www_authenticate_header(ctx, error_code, error_description)
    local tmpl = config.get_bk_apigateway_api_tmpl()

    -- If tmpl is not configured (nil or empty) or has no valid origin, use a minimal challenge.
    local challenge = 'Bearer realm="bk-apigateway"'
    if tmpl ~= nil and tmpl ~= "" then
        -- The tmpl can be in two formats:
        -- - subpath: http://bkapi.example.com/api/{api_name}
        -- - subdomain: http://{api_name}.bkapi.example.com

        -- Step 1: Replace {api_name} with "bk-apigateway" to get the base URL
        local base_url = string_gsub(tmpl, "{api_name}", "bk-apigateway")

        -- Step 2: Extract scheme and domain (host) from the rendered URL to get the origin
        -- Pattern matches: scheme://host (stops at first / after host or end of string)
        local gateway_name = (ctx and ctx.var and ctx.var.bk_gateway_name) or "unknown"
        local rendered_url = string_gsub(tmpl, "{api_name}", gateway_name)
        local rendered_origin = string_match(rendered_url, "^(https?://[^/]+)")
        if rendered_origin then
            -- Step 3: Build the resource path and encode it
            local path = (ctx and ctx.var and ctx.var.uri) or "/"

            -- In some envs, nginx rewrites subdomain to subpath, so the path has an extra /api/{gateway_name} prefix
            -- e.g. /api/bk-apigateway/prod/api/v2/... should be /prod/api/v2/...
            if config.should_strip_subpath_prefix() then
                path = strip_subpath_prefix(path, gateway_name)
            end
            local resource_url = rendered_origin .. path
            local encoded_resource_url = ngx_escape_uri(resource_url)

            challenge = string_format(
                'Bearer resource_metadata="%s/prod/api/v2/open/.well-known/oauth-protected-resource?resource=%s"',
                base_url,
                encoded_resource_url
            )
        end
    end

    if error_code and error_description then
        return challenge .. string_format(
            ', error="%s", error_description="%s"',
            escape_auth_header_value(error_code),
            escape_auth_header_value(error_description)
        )
    end
    return challenge
end


---Check whether the app code belongs to a real BlueKing app instead of a builtin OAuth2 client
---@param app_code string|nil
---@return boolean
function _M.is_real_app_code(app_code)
    return type(app_code) == "string" and app_code ~= "" and not BUILTIN_CLIENT_APP_CODES[app_code]
end


---The rejection reason when a resource requires a user but a real app OAuth2 token does not carry one.
---Shared by bk-auth-validate and bk-oauth2-appcode-validate so both return the same 401 reason.
---@param token_mode string|nil ctx.var.bk_oauth2_token_mode
---@param user table|nil ctx.var.bk_user
---@return string|nil reason nil when the token carries a verified user
function _M.get_user_required_token_reject_reason(token_mode, user)
    if token_mode ~= "delegated" then
        return "the resource requires a user, only OAuth2 delegated tokens are allowed"
    end

    if not user or not user.verified then
        return "the OAuth2 delegated token does not carry a valid user"
    end

    return nil
end


local function re_match(subject, pattern, field)
    local from, _, err = ngx_re_find(subject, pattern, "jo")
    if err then
        core.log.error("invalid bk_oauth2.bearer_token_rules ", field, "=", pattern,
                       ", error: ", err)
        return false
    end

    return from ~= nil
end


local function check_pattern(pattern, field, index)
    if type(pattern) ~= "string" then
        return "bearer_token_rules[" .. index .. "]." .. field .. " must be a string"
    end

    local _, _, err = ngx_re_find("", pattern, "jo")
    if err then
        return "bearer_token_rules[" .. index .. "]." .. field .. "=" .. pattern .. " is invalid: " .. err
    end

    return nil
end


---Validate bk_gateway.bk_oauth2.bearer_token_rules without changing how requests are matched.
---Used at plugin init to report misconfiguration once instead of only at request time.
---@return table problems A list of problem descriptions, empty when valid or not configured
function _M.validate_bkauth_bearer_token_rules()
    local rules = config.get_oauth2_bearer_token_rules()
    if rules == nil then
        return {}
    end

    if type(rules) ~= "table" or not table_isarray(rules) then
        return { "bearer_token_rules must be a list, treated as not configured" }
    end

    if #rules == 0 then
        return { "bearer_token_rules is empty and matches no Bearer tokens" }
    end

    local problems = {}
    for index, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            table_insert(problems, "bearer_token_rules[" .. index .. "] must be an object")
        else
            local problem = check_pattern(rule.prefix_pattern, "prefix_pattern", index)
            if problem then
                table_insert(problems, problem)
            end

            if rule.format_pattern ~= nil then
                problem = check_pattern(rule.format_pattern, "format_pattern", index)
                if problem then
                    table_insert(problems, problem)
                end
            end
        end
    end

    return problems
end


---Whether bk_gateway.bk_oauth2.bearer_token_rules is configured (an empty list counts as configured)
---@return boolean
function _M.has_bkauth_bearer_token_rules()
    return get_bkauth_bearer_token_rules() ~= nil
end


---Classify a Bearer token by the bkauth token rules (bk_gateway.bk_oauth2.bearer_token_rules).
---The first rule whose prefix_pattern matches decides; format_pattern is optional.
---@param token string The Bearer token
---@return string|nil kind "bkauth": verify it by bkauth; "malformed": a rule prefix matches but its
---    format does not; "other": no rule matches, not a bkauth token; nil: the rules are not configured
function _M.classify_bearer_token(token)
    local rules = get_bkauth_bearer_token_rules()
    if rules == nil then
        return nil
    end

    for _, rule in ipairs(rules) do
        if type(rule) == "table" and type(rule.prefix_pattern) == "string"
            and re_match(token, rule.prefix_pattern, "prefix_pattern") then
            if type(rule.format_pattern) ~= "string"
                or re_match(token, rule.format_pattern, "format_pattern") then
                return "bkauth"
            end
            return "malformed"
        end
    end

    return "other"
end


if _TEST then -- luacheck: ignore
    _M._escape_auth_header_value = escape_auth_header_value
    _M._strip_subpath_prefix = strip_subpath_prefix
end

return _M
