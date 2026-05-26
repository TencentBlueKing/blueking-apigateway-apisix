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

-- # bk-tenant-validate-exempt
--
-- When this plugin is attached to a resource, it exempts the resource from
-- bk-tenant-validate checks by setting a skip flag in the request context.

local core = require("apisix.core")

local plugin_name = "bk-tenant-validate-exempt"
local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 17676,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.rewrite(conf, ctx) -- luacheck: ignore
    ctx.var.bk_skip_tenant_validate = true
end

return _M
