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

-- The bk-thunderstone.lua is replaced by bk-permission
-- we need this for one more version, otherwise the bk-thunderstone will alllow all requests while upgrading
-- delete this file at 0.8.x(or 1.1.x)
local permission = require("apisix.plugins.bk-permission")
local core = require("apisix.core")

local plugin_name = "bk-thunderstone"

local _M = {
    version = 0.1,
    priority = 17640,
    name = plugin_name,
    schema = core.table.deepcopy(permission.schema),
    check_schema = permission.check_schema,
    init = permission.init,
    access = permission.access,
}

return _M
