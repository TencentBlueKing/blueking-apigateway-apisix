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

local pl_stringx = require("pl.stringx")
local tonumber = tonumber

local _M = {}

--- func desc
---@param list_string string
---@param sep? string @default to ", "
---@return string|nil
local function get_last_item(list_string, sep)
    if not list_string then
        return nil
    end
    if not sep then
        sep = ", "
    end
    local splited = pl_stringx.split(list_string, sep)
    if not splited then
        return nil
    end
    return splited[#splited]
end

---get_last_upstream_bytes_received get the last upstream bytes received
---this will make sense after or in header_filter phase
---@param ctx apisix.Context
---@return number|nil
function _M.get_last_upstream_bytes_received(ctx)
    return tonumber(get_last_item(ctx.var.upstream_bytes_received))
end

if _TEST then
    _M._get_last_item = get_last_item
end

return _M
