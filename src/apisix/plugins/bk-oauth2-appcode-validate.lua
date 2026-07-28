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
-- Validate whether an OAuth2 token's application code is enabled by plugin attributes.
--
-- This plugin only runs when ctx.var.is_bk_oauth2 == true.
--
-- This plugin depends on:
--     * bk-oauth2-verify: To set ctx.var.bk_app_code
--
local core = require("apisix.core")
local apisix_plugin = require("apisix.plugin")
local errorx = require("apisix.plugins.bk-core.errorx")
local oauth2 = require("apisix.plugins.bk-core.oauth2")
local ngx = ngx
local tostring = tostring

local plugin_name = "bk-oauth2-appcode-validate"

local schema = {
    type = "object",
    properties = {},
}

local attr_schema = {
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
    },
}

local _M = {
    version = 0.1,
    priority = 17677,
    name = plugin_name,
    schema = schema,
    attr_schema = attr_schema,
}

local support_public = false
local support_personal = false
local allowed_app_codes = {}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function reset_validation_state()
    support_public = false
    support_personal = false
    allowed_app_codes = {}
end


local function get_validation_state()
    return {
        support_public = support_public,
        support_personal = support_personal,
        allowed_app_codes = allowed_app_codes,
    }
end


function _M.init()
    reset_validation_state()

    local plugin_info = apisix_plugin.plugin_attr(plugin_name) or {}
    local ok, err = core.schema.check(attr_schema, plugin_info)
    if not ok then
        core.log.error(
            "failed to check plugin_attr[", plugin_name, "]: ", err,
            ", fail closed with no allowed app codes"
        )
        return
    end

    support_public = plugin_info.support_public == true
    support_personal = plugin_info.support_personal == true

    if support_public then
        allowed_app_codes.public = true
    end

    if support_personal then
        allowed_app_codes.personal = true
    end

    core.log.info(
        plugin_name .. ": initialized",
        ", support_public=", support_public,
        ", support_personal=", support_personal,
        ", allowed_app_codes=", core.json.encode(allowed_app_codes)
    )
end


local function build_error_description(app_code)
    return "OAuth2 token app code is not allowed: bk_app_code=" .. app_code ..
        ", support_public=" .. tostring(support_public) ..
        ", support_personal=" .. tostring(support_personal)
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    if ctx.var.is_bk_oauth2 ~= true then
        core.log.info(
            plugin_name .. ": skipping",
            ", is_bk_oauth2=", ctx.var.is_bk_oauth2
        )
        return
    end

    local app_code = ctx.var.bk_app_code or ""

    core.log.info(
        plugin_name .. ": checking",
        ", bk_app_code=", app_code,
        ", support_public=", support_public,
        ", support_personal=", support_personal
    )

    if app_code ~= "" and allowed_app_codes[app_code] then
        core.log.info(
            plugin_name .. ": validation passed",
            ", bk_app_code=", app_code,
            ", support_public=", support_public,
            ", support_personal=", support_personal
        )
        return
    end

    core.log.info(
        plugin_name .. ": validation failed",
        ", bk_app_code=", app_code,
        ", support_public=", support_public,
        ", support_personal=", support_personal
    )

    local error_description = build_error_description(app_code)
    local err = errorx.new_general_unauthorized():with_fields(
        {
            reason = "OAuth2 token app code is not allowed",
            bk_app_code = app_code,
            support_public = support_public,
            support_personal = support_personal,
        }
    )

    ngx.header["WWW-Authenticate"] = oauth2.build_www_authenticate_header(
        ctx, "invalid_token", error_description
    )
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._get_validation_state = get_validation_state
end

return _M
