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
-- # bk-oauth2-appcode-validate
--
-- Validate whether an OAuth2 token's application code is enabled by route configuration.
--
--     * "public" / "personal": allowed by support_public / support_personal
--     * a real BlueKing app: allowed by support_app, and the token mode must match the resource:
--         - the resource requires a user: only a delegated token with a verified user
--         - the resource does not require a user: only an app token
--
-- This plugin only runs when ctx.var.is_bk_oauth2 == true.
--
-- This plugin depends on:
--     * bk-oauth2-verify: To set ctx.var.bk_app_code, ctx.var.bk_user and ctx.var.bk_oauth2_token_mode
--     * bk-resource-context: To set ctx.var.bk_resource_auth
--
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local oauth2 = require("apisix.plugins.bk-core.oauth2")
local ngx = ngx
local tostring = tostring

local plugin_name = "bk-oauth2-appcode-validate"

local schema = {
    type = "object",
    properties = {
        support_public = {
            type = "boolean",
            default = false,
        },
        support_personal = {
            type = "boolean",
            default = false,
        },
        support_app = {
            type = "boolean",
            default = false,
        },
    },
}

local _M = {
    version = 0.1,
    priority = 17678,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function log_validation(phase, app_code, conf, ctx)
    core.log.info(
        plugin_name .. ": " .. phase,
        ", bk_app_code=", app_code,
        ", support_public=", conf.support_public,
        ", support_personal=", conf.support_personal,
        ", support_app=", conf.support_app,
        ", token_mode=", ctx.var.bk_oauth2_token_mode,
        ", gateway=", ctx.var.bk_gateway_name,
        ", resource=", ctx.var.bk_resource_name
    )
end


---Validate the token of a real BlueKing app against the route and resource configuration
---@return string|nil reason The rejection reason, nil when the token is allowed
local function validate_real_app(conf, ctx)
    if not conf.support_app then
        return "OAuth2 token app code is not allowed"
    end

    local user_required = true
    local resource_auth = ctx.var.bk_resource_auth
    if resource_auth then
        user_required = resource_auth:get_verified_user_required()
    end

    local token_mode = ctx.var.bk_oauth2_token_mode
    if user_required then
        if token_mode ~= "delegated" then
            return "the resource requires a user, only OAuth2 delegated tokens are allowed"
        end

        local user = ctx.var.bk_user
        if not user or not user.verified then
            return "the OAuth2 delegated token does not carry a valid user"
        end
        return nil
    end

    if token_mode ~= "app" then
        return "the resource does not require a user, only OAuth2 app tokens are allowed"
    end
    return nil
end


function _M.rewrite(conf, ctx)
    if ctx.var.is_bk_oauth2 ~= true then
        core.log.info(
            plugin_name .. ": skipping",
            ", is_bk_oauth2=", ctx.var.is_bk_oauth2,
            ", gateway=", ctx.var.bk_gateway_name,
            ", resource=", ctx.var.bk_resource_name
        )
        return
    end

    local app_code = ctx.var.bk_app_code or ""

    log_validation("checking", app_code, conf, ctx)

    if app_code == "public" and conf.support_public then
        log_validation("validation passed", app_code, conf, ctx)
        return
    end

    if app_code == "personal" and conf.support_personal then
        log_validation("validation passed", app_code, conf, ctx)
        return
    end

    local reason = "OAuth2 token app code is not allowed"
    if oauth2.is_real_app_code(app_code) then
        reason = validate_real_app(conf, ctx)
        if not reason then
            log_validation("validation passed", app_code, conf, ctx)
            return
        end
    end

    log_validation("validation failed", app_code, conf, ctx)

    local token_mode = ctx.var.bk_oauth2_token_mode or ""
    local err = errorx.new_general_unauthorized():with_fields(
        {
            reason = reason,
            bk_app_code = app_code,
            support_public = conf.support_public,
            support_personal = conf.support_personal,
            support_app = conf.support_app,
            token_mode = token_mode,
            gateway = ctx.var.bk_gateway_name or "",
            resource = ctx.var.bk_resource_name or "",
        }
    )

    ngx.header["WWW-Authenticate"] = oauth2.build_www_authenticate_header(
        ctx,
        "invalid_token",
        reason .. ": bk_app_code=" .. app_code ..
            ", support_public=" .. tostring(conf.support_public) ..
            ", support_personal=" .. tostring(conf.support_personal) ..
            ", support_app=" .. tostring(conf.support_app) ..
            ", token_mode=" .. token_mode
    )
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._validate_real_app = validate_real_app
end

return _M
