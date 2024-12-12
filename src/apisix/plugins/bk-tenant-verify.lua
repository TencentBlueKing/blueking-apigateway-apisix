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

-- # bk-tenant-verify.lua
--
-- this plugin only get the tenant_info from
--   - header => ctx.var.header_tenant_id
--   - bkauth(app.tenant_mode/app.tenant_id) => ctx.var.bk_app
--   - bkuser(user.tenant_id) => ctx.var.bk_user
-- it do nothing, would not return any response, just for the tenant info validation.


local core = require("apisix.core")


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
    local header_tenant_id = core.request.header(ctx, BKAPI_TENANT_ID_HEADER)
    ctx.var.header_tenant_id = header_tenant_id

    -- 2. get tenant_id from bkauth(app.tenant_mode/app.tenant_id)
    if ctx.var.bk_app:get_app_code() ~= "" and ctx.var.bk_app:is_verified() then
        -- FIXME: get tenant_mode and tenant_id from bkauth
        ctx.var.bk_app.tenant_mode = "single"
        ctx.var.bk_app.tenant_id = "hello"
    end

    -- 3. get tenant_id from bkuser(user.tenant_id)
    if ctx.var.bk_user:get_username() ~= "" and ctx.var.bk_user:is_verified() then
        -- FIXME: get tenant_id from bkuser
        ctx.var.bk_user.tenant_id = "hello"
    end
end

return _M

