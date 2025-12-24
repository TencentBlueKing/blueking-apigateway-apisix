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
-- bk-permission
--
-- Check the permission of the app to access the gateway resource.
--
-- Fetch the app permisson data for resource throuth the api of the core-api service.
-- The permission has two dimensions:
-- - by gateway: The app has permissions to all resources under the gateway
-- - by resource: The app has permission to the specified resource
--
-- core-api service api:
-- GET http://bk-apigateway-core-api/api/v1/micro-gateway/{micro_instance_id}/permissions/
-- request params:
--   bk_gateway_name={bk_gateway_name}
--   bk_resource_name={bk_resource_name}
--   bk_stage_name={bk_stage_name}
--   bk_app_code={bk_app_code}
-- request headers:
--   X-Bk-Micro-Gateway-Instance-Id: {micro_instance_id}
--   X-Bk-Micro-Gateway-Instance-Secret: {micro_instance_secret}
-- response body:
--     {
--         "data": {
--             "{bk_gateway_name}:-:{bk_app_code}": 1683523681,                  # 按网关的权限
--             "{bk_gateway_name}:{bk_resource_name}:{bk_app_code}": 1658546464  # 按资源的权限
--         }
--     }
--
-- This plugin depends on:
--    * bk-auth-verify: Get the verified bk_app_code
--
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local cache_fallback = require("apisix.plugins.bk-cache-fallback.init")
local bk_apigateway_core_component = require("apisix.plugins.bk-components.bk-apigateway-core")
local pl_types = require("pl.types")
local pl_tablex = require("pl.tablex")
local ngx_time = ngx.time

-- this plugin is used to check the permission of the app_code => gateway or app_code => resource
local plugin_name = "bk-permission"

local reason_no_perm = "no permission"
local reason_perm_expired = "permission has expired"

local schema = {}

local _M = {
    version = 0.1,
    priority = 17640,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local cache

function _M.init()
    cache = cache_fallback.new(
        {
            lrucache_max_items = 10240, -- key is gateway+resource+app_code, so maybe a lot of keys
            lrucache_ttl = 90,
            lrucache_short_ttl = 2, -- cache failed response for 2 seconds
            fallback_cache_ttl = 60 * 60 * 24, -- if core-api is down, use the fallback cache data generated in 24 hours
        }, plugin_name
    )
end

---@param gateway_name string @the name of the gateway
---@param resource_name string @the name of the resource
---@param app_code string @the name of the app_code
local function query_permission(gateway_name, stage_name, resource_name, app_code)
    local data, err = bk_apigateway_core_component.query_permission(gateway_name, stage_name, resource_name, app_code)
    return data, err
end

---@param conf any
---@param ctx apisix.Context
function _M.access(conf, ctx)
    -- just call the bk-permission directly
    if ctx.var.bk_resource_auth.resource_perm_required == false then
        return
    end

    local app_code = ctx.var.bk_app_code

    if pl_types.is_empty(app_code) then
        return errorx.exit_with_apigw_err(
            ctx, errorx.new_app_no_permission():with_fields(
                {
                    reason = "if resource_perm_required is true, verified_app_required must be set to true too, " ..
                        "please contact the managers of the gateway to handle.",
                }
            ), _M
        )
    end

    local gateway_name = ctx.var.bk_gateway_name
    local resource_name = ctx.var.bk_resource_name
    local stage_name = ctx.var.bk_stage_name

    -- get data from lrucache -> http api; if http api failed, use the fallback cache(shared_dict)
    local key = gateway_name .. ":" .. resource_name .. ":" .. app_code
    local data, err = cache:get_with_fallback(
        ctx, key, nil, query_permission, gateway_name, stage_name, resource_name, app_code
    )
    if err ~= nil then
        return errorx.exit_with_apigw_err(ctx, errorx.new_internal_server_error():with_field("reason", err), _M)
    end

    -- 0. no permission records, return app_no_permission
    if pl_types.is_empty(data) then
        local reason = reason_no_perm .. ", bk_app_code=" .. app_code
        return errorx.exit_with_apigw_err(
            ctx, errorx.new_app_no_permission():with_field("reason", reason), _M
        )
    end

    local now = ngx_time()

    -- 1. check gateway permission
    local gateway_perm_key = ctx.var.bk_gateway_name .. ":-:" .. ctx.var.bk_app_code

    local gateway_perm_expires = data[gateway_perm_key]
    if gateway_perm_expires ~= nil then
        if gateway_perm_expires > now then
            return
        else
            -- if only has one record, means expired
            if pl_tablex.size(data) == 1 then
                -- expired: permission has expired
                local reason = reason_perm_expired .. ", type=gateway_permission, bk_app_code=" .. app_code
                return errorx.exit_with_apigw_err(
                    ctx, errorx.new_app_no_permission():with_field("reason", reason), _M
                )
            end

        end
    end

    -- 1. check resource permission
    local resource_perm_key = key
    local resource_perm_expires = data[resource_perm_key]
    if resource_perm_expires ~= nil then
        if resource_perm_expires > now then
            return
        else
            -- expired: permission has expired
            local reason = reason_perm_expired .. ", type=resource_permission, bk_app_code=" .. app_code
            return errorx.exit_with_apigw_err(
                ctx, errorx.new_app_no_permission():with_field("reason", reason), _M
            )
        end
    end

    -- no permission
    return errorx.exit_with_apigw_err(ctx, errorx.new_app_no_permission():with_field("reason", reason_no_perm), _M)
end

if _TEST then
    _M._query_permission = query_permission
    _M._get_cache = function()
        return cache
    end
end

return _M
