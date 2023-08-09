--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
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
local errorx = require("apisix.plugins.bk-core.errorx")
local bk_auth_verify_init = require("apisix.plugins.bk-auth-verify.init")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local ipairs = ipairs
local tostring = tostring

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
    if auth_params == nil then
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
---Use closures, execute multiple times, and only get the result of the first calculation.
---@param ctx table The current context object.
---@param authorization_keys table The possible collection of auth-related keys, defined in the config.
---@return function get_auth_params function.
local function get_auth_params_from_request(ctx, authorization_keys)
    local auth_params, err

    local function get_auth_params()
        if auth_params ~= nil or err ~= nil then
            return auth_params, err
        end

        -- 请求头 X-Bkapi-Authorization 只要存在，则使用此数据作为认证信息，若不存在，则从参数中获取认证信息
        auth_params, err = get_auth_params_from_header(ctx)
        if auth_params == nil and err == nil then
            -- from the querystring and body
            auth_params, err = get_auth_params_from_parameters(ctx, authorization_keys), nil
        end

        return auth_params, err
    end

    return get_auth_params
end
-- utils end

-- app utils start

---Check if the current request is exempt from the requirement to provide a verified user.
---@param app_code string The Application code.
---@param bk_resource_id integer The ID of current resource.
---@param verified_user_exempted_apps table The whitelist configuration data of current gateway.
---@return boolean The result.
local function is_app_exempted_from_verified_user(app_code, bk_resource_id, verified_user_exempted_apps)
    if pl_types.is_empty(app_code) or verified_user_exempted_apps == nil then
        return false
    end

    if verified_user_exempted_apps.by_gateway[app_code] == true then
        return true
    end

    if bk_resource_id ~= nil and verified_user_exempted_apps.by_resource[app_code] and
        verified_user_exempted_apps.by_resource[app_code][tostring(bk_resource_id)] == true then
        return true
    end

    return false
end

---Verify the incoming request, try to get the app objects from it.
---@param ctx table Current context object.
---@param get_auth_params_func function Get authentication related parameters.
---@return table app The app object, is an anonymous object when verification is not performed or failed.
---@return boolean has_server_error During verification, whether there is a server error.
local function verify_app(ctx, get_auth_params_func)
    -- Return directly if "bk-resource-context" is not loaded by checking "bk_resource_auth"
    if ctx.var.bk_resource_auth == nil then
        return bk_app_define.new_anonymous_app('verify skipped, the "bk-resource-context" plugin is not configured'),
               true
    end

    -- get auth-params from request, skip further process when failed to get a valid
    -- params, If the parameters are empty, further processing still continues.
    local auth_params, err = get_auth_params_func()
    if auth_params == nil then
        return bk_app_define.new_anonymous_app(err), false
    end

    local auth_params_obj = auth_params_mod.new(auth_params)
    local verifier = bk_auth_verify_init.new(auth_params_obj, ctx.var.bk_api_auth, ctx.var.bk_resource_auth)

    return verifier:verify_app()
end

---Validate the given app object.
---@param bk_resource_auth table
---@param app table
---@return table|nil apigwerr An apigw error when invalid.
local function validate_app(bk_resource_auth, app, has_server_error)
    -- Return directly if "bk-resource-context" is not loaded by checking "bk_resource_auth"
    if bk_resource_auth == nil then
        return
    end

    if not bk_resource_auth:get_verified_app_required() then
        return
    end

    if app.verified then
        return
    end

    if has_server_error then
        return errorx.new_internal_server_error():with_field("reason", app.valid_error_message)
    end

    return errorx.new_invalid_args():with_field("reason", app.valid_error_message)
end

-- app utils end

-- user utils start

---Verify the incoming request, try to get the user objects from it.
---@param ctx table Current context object.
---@return table user the user object, is an anonymous object when verification is not performed or failed.
---@return boolean has_server_error During verification, whether there is a server error.
local function verify_user(ctx, get_auth_params_func)
    -- Return directly if "bk-resource-auth" is not loaded by checking "bk_resource_auth"
    if ctx.var.bk_resource_auth == nil then
        return bk_user_define.new_anonymous_user('verify skipped, the "bk-resource-context" plugin is not configured'),
               true
    end

    -- get auth-params from request, skip further process when failed to get a valid
    -- params, If the parameters are empty, further processing still continues.
    local auth_params, err = get_auth_params_func()
    if auth_params == nil then
        return bk_user_define.new_anonymous_user(err), false
    end

    local auth_params_obj = auth_params_mod.new(auth_params)
    local verifier = bk_auth_verify_init.new(auth_params_obj, ctx.var.bk_api_auth, ctx.var.bk_resource_auth)

    return verifier:verify_user()
end

---@return table|nil apigwerr An apigw error when invalid.
local function validate_user(bk_resource_id, bk_resource_auth, user, app, verified_user_exempted_apps, has_server_error)
    -- Return directly if "bk-resource-auth" is not loaded by checking "bk_resource_auth"
    if bk_resource_auth == nil then
        return
    end

    if (not bk_resource_auth:get_verified_user_required() or
        is_app_exempted_from_verified_user(app:get_app_code(), bk_resource_id, verified_user_exempted_apps) or
        bk_resource_auth:get_skip_user_verification()) then
        return
    end

    if user.verified then
        return
    end

    if has_server_error then
        return errorx.new_internal_server_error():with_field("reason", user.valid_error_message)
    end

    return errorx.new_invalid_args():with_field("reason", user.valid_error_message)
end

-- user utils end

function _M.rewrite(conf, ctx) -- luacheck: no unused
    local get_auth_params_func = get_auth_params_from_request(ctx, bk_core.config.get_authorization_keys())

    local app, has_server_error = verify_app(ctx, get_auth_params_func)
    local apigwerr = validate_app(ctx.var.bk_resource_auth, app, has_server_error)
    if apigwerr ~= nil then
        return errorx.exit_with_apigw_err(ctx, apigwerr, _M)
    end

    local user
    user, has_server_error = verify_user(ctx, get_auth_params_func)
    apigwerr = validate_user(
        ctx.var.bk_resource_id, ctx.var.bk_resource_auth, user, app, ctx.var.verified_user_exempted_apps,
        has_server_error
    )
    if apigwerr ~= nil then
        return errorx.exit_with_apigw_err(ctx, apigwerr, _M)
    end

    ctx.var.bk_app = app
    ctx.var.bk_user = user
    ctx.var.bk_app_code = app["app_code"]
    ctx.var.bk_username = user["username"]
end

if _TEST then -- luacheck: ignore
    _M._get_auth_params_from_header = get_auth_params_from_header
    _M._get_auth_params_from_parameters = get_auth_params_from_parameters
    _M._get_auth_params_from_request = get_auth_params_from_request
    _M._verify_app = verify_app
    _M._validate_app = validate_app
    _M._verify_user = verify_user
    _M._validate_user = validate_user
    _M._is_app_exempted_from_verified_user = is_app_exempted_from_verified_user
end

return _M
