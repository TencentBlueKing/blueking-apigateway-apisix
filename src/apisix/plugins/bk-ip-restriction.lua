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

local core = require("apisix.core")
local base = require("apisix.plugins.ip-restriction.init")
local errorx = require("apisix.plugins.bk-core.errorx")

local _M = {
    version = base.version,
    priority = 17662,
    name = "bk-ip-restriction",
    schema = core.table.deepcopy(base.schema),
    check_schema = base.check_schema,
}

---@param conf any
---@param ctx apisix.Context
function _M.access(conf, ctx)
    -- ip matcher lrucache for: 300s, 512 items
    -- make your own lrucache if necessarily
    local code, result = base.restrict(conf, ctx)
    if not code then
        return
    end

    return errorx.exit_with_apigw_err(
        ctx, errorx.new_ip_not_allowed():with_fields(
            {
                ip = ctx.var.remote_addr,
                reason = result.message,
            }
        ), _M
    )
end

return _M
