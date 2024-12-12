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

-- # bk-tenant-validate
--
-- this plugin will validate the tenant info of all source
--   - header_tenant_id
--   - bk_app.tenant_mode/bk_app.tenant_id
--   - bk_user.tenant_id
--   - gateway.tenant_mode/gateway.tenant_id

local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")

local BKAPI_TENANT_ID_HEADER = "X-Bk-Tenant-Id"

local plugin_name = "bk-tenant-validate"
local schema = {
    type = "object",
    properties = {
        tenant_mode = {
            type = "string",
            enum = {"global", "single"},
            description = "tenant mode of gateway, global: all tenant can access, single: only the tenant can access",
        },
        tenant_id = {
            type = "string",
            description = "tenant id of gateway, if mode is global, the tenant_id is empty string",
        },
    },
    required = {"tenant_mode", "tenant_id"},
}

local _M = {
    version = 0.1,
    priority = 17674,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function is_empty(value)
    return value == nil or value == ""
end


local function reject_cross_tenant(err_msg)
    return errorx.new_cross_tenant_forbidden():with_field("reason", err_msg)
end

local function validate_app_tenant_id(
    ctx,
    gateway_tenant_mode, gateway_tenant_id,
    app_tenant_mode, app_tenant_id,
    header_tenant_id
)
    -- 全租户应用， 可以传递任意 X-Bk-Tenant-Id
    if app_tenant_mode == "global" then
        -- 没有传递`X-Bk-Tenant-Id`, reject
        -- 【全租户应用调用第三方必须设置header头，改造是必须的】
        if is_empty(header_tenant_id) then
            local err_msg = string.format(
                "Cross-tenant calls are not allowed: header X-Bk-Tenant-Id is required. the app %s tenant_mode=%s",
                ctx.var.bk_app:get_app_code(), app_tenant_mode
            )
            return reject_cross_tenant(err_msg)
        end
        -- 传递`X-Bk-Tenant-Id`， 通过，不做其他检查
        --【全租户应用可以传递任意 X-Bk-Tenant-Id】
    else
        -- `app_tenant_id != header_tenant_id`，返回 403 【X-Bk-Tenant-Id必须是本租户】
        if app_tenant_id ~= header_tenant_id then
            local err_msg = string.format(
                "Cross-tenant calls are not allowed: current header X-Bk-Tenant-Id=%s, "..
                "should be the same as app's tenant_id=%s, while the app's tenant_mode=%s",
                header_tenant_id, app_tenant_id, app_tenant_mode
            )
            return reject_cross_tenant(err_msg)
        end

        -- 只能调用本租户下的网关 以及 全租户网关
        if gateway_tenant_mode ~= "global" and gateway_tenant_id ~= app_tenant_id then
            local err_msg = string.format(
                "Cross-tenant calls are not allowed: gateway %s belongs to tenant %s, app %s belongs to tenant %s",
                ctx.var.bk_gateway_name,gateway_tenant_id,
                ctx.var.bk_app:get_app_code(),app_tenant_id
            )
            return reject_cross_tenant(err_msg)
        end
    end
end

local function validate_user_tenant_id(ctx, gateway_tenant_mode, gateway_tenant_id, app_tenant_mode, app_tenant_id)
    local user_tenant_id = ctx.var.bk_user.tenant_id

    -- 某个租户的用户，只能调用本租户或全租户的网关
    if gateway_tenant_mode ~= "global" and gateway_tenant_id ~= user_tenant_id then
        local err_msg = string.format(
            "Cross-tenant calls are not allowed: gateway %s belongs to tenant %s, user %s belongs to tenant %s",
            ctx.var.bk_gateway_name,gateway_tenant_id,
            ctx.var.bk_user:get_username(), user_tenant_id
        )
        return reject_cross_tenant(err_msg)
    end

    -- 开启了应用认证，那么应用只能使用本租户的用户态
    if app_tenant_mode ~= nil and app_tenant_mode ~= "" then
        --【禁止跨租户，单租户应用只能处理使用本租户用户的应用态】
        if app_tenant_mode ~= "global" and app_tenant_id ~= user_tenant_id then
            local err_msg = string.format(
                "Cross-tenant calls are not allowed: app %s belongs to tenant %s, user %s belongs to tenant %s",
                ctx.var.bk_app:get_app_code(),app_tenant_id,
                ctx.var.bk_user:get_username(), user_tenant_id
            )
            return reject_cross_tenant(err_msg)
        end
    end

end

local function validate_header_tenant_id(ctx, gateway_tenant_mode, gateway_tenant_id, header_tenant_id)
    if header_tenant_id ~= nil and header_tenant_id ~= "" then
        if gateway_tenant_mode ~= "global" and gateway_tenant_id ~= header_tenant_id then
            local err_msg = string.format(
                "Cross-tenant calls are not allowed: gateway belongs to tenant %s, header tenant_id is %s",
                gateway_tenant_id, header_tenant_id
            )
            return reject_cross_tenant(err_msg)
        end
    end
end

function _M.rewrite(conf, ctx) -- luacheck: ignore
    local gateway_tenant_mode = conf.tenant_mode
    local gateway_tenant_id = conf.tenant_id

    local app_tenant_mode = ""
    local app_tenant_id = ""

    -- 1. app verified, check tenant_mode and tenant_id
    if ctx.var.bk_app:get_app_code() ~= "" and ctx.var.bk_app:is_verified() then
        app_tenant_mode = ctx.var.bk_app.tenant_mode
        app_tenant_id = ctx.var.bk_app.tenant_id

        -- 没有传递`X-Bk-Tenant-Id`, 设置默认值为 `app_tenant_id`
        -- 目的: 兼容所有存量应用（不会设置这个头）
        if app_tenant_mode ~= "global" and is_empty(ctx.var.header_tenant_id) then
            ctx.var.header_tenant_id = app_tenant_id
            core.request.set_header(ctx, BKAPI_TENANT_ID_HEADER, app_tenant_id)
        end

        local err = validate_app_tenant_id(
            ctx, gateway_tenant_mode, gateway_tenant_id, app_tenant_mode, app_tenant_id,
            ctx.var.header_tenant_id
        )
        if err ~= nil then
            return errorx.exit_with_apigw_err(ctx, err, _M)
        end

    end

    -- 2. user verified, check tenant_id
    if ctx.var.bk_user:get_username() ~= "" and ctx.var.bk_user:is_verified() then
        local err = validate_user_tenant_id(
            ctx, gateway_tenant_mode, gateway_tenant_id, app_tenant_mode, app_tenant_id
        )
        if err ~= nil then
            return errorx.exit_with_apigw_err(ctx, err, _M)
        end
    end

    -- 3. header tenant_id verify
    local err = validate_header_tenant_id(ctx, gateway_tenant_mode, gateway_tenant_id, ctx.var.header_tenant_id)
    if err ~= nil then
        return errorx.exit_with_apigw_err(ctx, err, _M)
    end

    -- 4. set the bk_tenant_id
    -- FIXME: bk_tenant_id means header_tenant_id? or just use header_tenant_id?
    ctx.var.bk_tenant_id = ctx.var.header_tenant_id

end

return _M