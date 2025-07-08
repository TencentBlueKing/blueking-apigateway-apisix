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

-- # bk-status-rewrite
--
-- the status code will be rewrited to 200, if the route configure the bk-status-rewrite plugin.
-- it set the `ctx.var.bk_status_rewrite_200 = true`, and do the status code rewrite in `errorx.lua:exit_plugin()`
-- note: this is a legacy plugin, and will be removed in the future. please not use it in other conditions.

local core = require("apisix.core")

local plugin_name = "bk-status-rewrite"
local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 18815,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx) -- luacheck: ignore
    -- 为上下文注入信息
    ctx.var.bk_status_rewrite_200 = true
end

return _M
