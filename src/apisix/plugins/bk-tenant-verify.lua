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

-- # bk-tenant-verify.lua
--
-- this plugin only get the tenant_info from
--   - header => ctx.var.header_tenant_id
--   - bkauth(app.tenant_mode/app.tenant_id) => ctx.var.bk_app
--   - bkuser(user.tenant_id) => ctx.var.bk_user
-- it do nothing, would not return any response, just for the tenant info validation.


local core = require("apisix.core")
local bk_cache = require("apisix.plugins.bk-cache.init")
local errorx = require("apisix.plugins.bk-core.errorx")

local BKAPI_TENANT_ID_HEADER = "X-Bk-Tenant-Id"

local plugin_name = "bk-tenant-verify"
local schema = {
    type = "object",
    properties = {
    }
}

local _M = {
    version = 0.1,
    priority = 17675,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx) -- luacheck: ignore
    -- 1. get tenant_id from header: X-Bk-Tenant-Id
    ctx.var.bk_tenant_id = core.request.header(ctx, BKAPI_TENANT_ID_HEADER)

    local app_code = ctx.var.bk_app:get_app_code()
    -- 2. get tenant_id from bkauth(app.tenant_mode/app.tenant_id)
    if app_code ~= "" and ctx.var.bk_app:is_verified() then
        local app_tenant_info, err = bk_cache.get_app_tenant_info(app_code)
        if err ~= nil then
            return errorx.exit_with_apigw_err(ctx, errorx.new_internal_server_error():with_field("reason", err), _M)
        end

        ctx.var.bk_app.tenant_mode = app_tenant_info.tenant_mode
        ctx.var.bk_app.tenant_id = app_tenant_info.tenant_id
    end

    -- 3. get tenant_id from bkuser(user.tenant_id)
    local username = ctx.var.bk_user:get_username()
    if username ~= "" and ctx.var.bk_user:is_verified() then
        local user_tenant_info, err = bk_cache.get_user_tenant_info(username)
        if err ~= nil then
            return errorx.exit_with_apigw_err(ctx, errorx.new_internal_server_error():with_field("reason", err), _M)
        end

        ctx.var.bk_user.tenant_id = user_tenant_info.tenant_id
    end
end

return _M

