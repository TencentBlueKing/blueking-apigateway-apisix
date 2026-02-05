--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
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
-- # bk-auth-verify
--
-- This plugin sets the authentication-related properties to the current context, including
-- "bk_app", "bk_user", "bk_username", etc. Other plugins may depend on this plugin to
-- provide advanced functionalities, such as permission checking and validation.
--
-- This plugin won't directly change the request flow, such as redirecting to another page
-- or returning an error response. Even if the verification fails or no parameters can be found,
-- the plugin use anonymous application and user objects.
--
-- This plugin depends on:
--     * bk-resource-context: To determine whether the user verification should be skipped.
--
local pl_types = require("pl.types")
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")
local bk_auth_verify_init = require("apisix.plugins.bk-auth-verify.init")
local app_account_verifier = require("apisix.plugins.bk-auth-verify.app-account-verifier")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local ipairs = ipairs

-- plugin config
local plugin_name = "bk-auth-verify"

local BKAPI_AUTHORIZATION_HEADER = "X-Bkapi-Authorization"

-- apisix.yaml
local schema = {
    type = "object",
    properties = {},
}

-- global config.yaml
local _M = {
    version = 0.1,
    priority = 18730,
    name = plugin_name,
    schema = schema,
}

-- apisix uses to check config
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- utils start
local function get_auth_params_from_header(ctx)
    local authorization = core.request.header(ctx, BKAPI_AUTHORIZATION_HEADER)
    if pl_types.is_empty(authorization) then
        return nil, nil
    end

    local auth_params = core.json.decode(authorization)
    if type(auth_params) ~= "table" then
        core.log.warn("the invalid X-Bkapi-Authorization: ", core.json.delay_encode(authorization))
        return nil, "request header X-Bkapi-Authorization is not a valid JSON"
    end

    return auth_params, nil
end

local function update_auth_params(data, authorization_keys, auth_params)
    if pl_types.is_empty(data) then
        return
    end

    for _, key in ipairs(authorization_keys) do
        local value = bk_core.url.get_value(data, key)
        if not pl_types.is_empty(value) then
            auth_params[key] = value
        end
    end
end

local function get_auth_params_from_parameters(ctx, authorization_keys)
    local auth_params = {}

    local uri_args = core.request.get_uri_args()
    local multipart_form_data = bk_core.request.parse_multipart_form(ctx)
    local json_body = bk_core.request.get_json_body()
    local form_data = bk_core.request.get_form_data(ctx)

    -- use pairs, some value should be nil
    update_auth_params(uri_args, authorization_keys, auth_params)
    update_auth_params(form_data, authorization_keys, auth_params)
    update_auth_params(json_body, authorization_keys, auth_params)
    update_auth_params(multipart_form_data, authorization_keys, auth_params)

    return auth_params
end

---Get the authentication related params from current request.
---@param ctx table The current context object.
---@param authorization_keys table The possible collection of auth-related keys, defined in the config.
---@return table|nil auth_params The params data.
---@return string|nil err The error message.
local function get_auth_params_from_request(ctx, authorization_keys)
    -- 请求头 X-Bkapi-Authorization 只要存在，则使用此数据作为认证信息，若不存在，则从参数中获取认证信息
    local auth_params, err = get_auth_params_from_header(ctx)
    if err ~= nil then
        return nil, err
    elseif auth_params ~= nil then
        -- 记录认证参数位置，便于统计哪些请求将认证参数放到请求参数，推动优化
        ctx.var.auth_params_location = "header"
        return auth_params, nil
    end

    if not ctx.var.bk_api_auth:allow_get_auth_params_from_parameters() then
        -- 不允许从请求参数获取认证参数，直接返回
        return {}, nil
    end

    -- from the querystring and body
    auth_params = get_auth_params_from_parameters(ctx, authorization_keys)

    if not pl_types.is_empty(auth_params) then
        -- 记录认证参数位置，便于统计哪些请求将认证参数放到请求参数，推动优化
        ctx.var.auth_params_location = "params"
    end

    return auth_params
end
-- utils end

---Verify the incoming request, try to get the app and user objects from it.
---@param ctx table Current context object.
---@return table app the app object, is an anonymous object when verification is not performed or failed.
---@return table user the user object, is an anonymous object when verification is not performed or failed.
function _M.verify(ctx)
    local app, user

    -- Return directly if "bk-resource-auth" is not loaded by checking "bk_resource_auth"
    if ctx.var.bk_resource_auth == nil then
        app = bk_app_define.new_anonymous_app('verify skipped, the "bk-resource-auth" plugin is not configured')
        user = bk_user_define.new_anonymous_user('verify skipped, the "bk-resource-auth" plugin is not configured')
        return app, user
    end

    -- get auth-params from request, skip further process when failed to get a valid
    -- params, If the parameters are empty, further processing still continues.
    local auth_params, err = get_auth_params_from_request(ctx, bk_core.config.get_authorization_keys())
    if auth_params == nil then
        app = bk_app_define.new_anonymous_app(err)
        user = bk_user_define.new_anonymous_user(err)
        return app, user
    end

    local auth_params_obj = auth_params_mod.new(auth_params)
    app = app_account_verifier.new(auth_params_obj):verify_app()

    local verifier = bk_auth_verify_init.new(auth_params_obj, ctx.var.bk_api_auth, ctx.var.bk_resource_auth, app)

    app, err = verifier:verify_app()
    if app == nil then
        app = bk_app_define.new_anonymous_app(err)
    end

    user, err = verifier:verify_user()
    if user == nil then
        user = bk_user_define.new_anonymous_user(err)
    end

    return app, user
end

function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- Skip if OAuth2 flow is handling authentication
    -- (is_bk_oauth2 is set by bk-oauth2-protected-resource plugin)
    if ctx.var.is_bk_oauth2 == true then
        return
    end

    local app, user = _M.verify(ctx)

    ctx.var.bk_app = app
    ctx.var.bk_user = user
    ctx.var.bk_app_code = app["app_code"]
    ctx.var.bk_username = user["username"]
    -- 记录认证参数位置，便于统计哪些请求将认证参数放到请求参数，推动优化
    ctx.var.auth_params_location = ctx.var.auth_params_location or ""
end

if _TEST then -- luacheck: ignore
    _M._get_auth_params_from_header = get_auth_params_from_header
    _M._get_auth_params_from_parameters = get_auth_params_from_parameters
    _M._get_auth_params_from_request = get_auth_params_from_request
end

return _M
