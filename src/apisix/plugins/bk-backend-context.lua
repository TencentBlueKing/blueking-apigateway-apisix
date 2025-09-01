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


-- bk-backend-context
--
-- This is a custom Apache APISIX plugin that is responsible
-- for injecting backend ID and backend name information
-- into the context.
--
-- Configurations:
-- bk_backend_id: The ID of the backend.
-- bk_backend_name: The name of the backend.



local core = require("apisix.core")

local plugin_name = "bk-backend-context"
local schema = {
    type = "object",
    properties = {
        bk_backend_id = {
            type = "integer",
        },
        bk_backend_name = {
            type = "string",
        },
    },
    required = {
        "bk_backend_id",
        "bk_backend_name",
    },
}

local _M = {
    version = 0.1,
    priority = 18825,
    name = plugin_name,
    schema = schema,
}

---@param conf table: the plugin configuration
function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    return true
end

---@param conf table: the plugin configuration
---@param ctx  apisix.Context
function _M.rewrite(conf, ctx)
    -- Inject bk_backend(id,name) information into the context
    ctx.var.bk_backend_id = conf.bk_backend_id
    ctx.var.bk_backend_name = conf.bk_backend_name
end

return _M
