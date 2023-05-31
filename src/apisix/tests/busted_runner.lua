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

local busted_resty = require("busted_resty")
busted_resty()

-- 记录所有测试过程中修改的变量
_NGXVALS = {}
local var_mt = {
    __index = function(tbl, key)
        local values = _NGXVALS[tbl]
        if values == nil then
            return nil
        end

        return values[key]
    end,
    __newindex = function(tbl, key, value)
        local values = _NGXVALS[tbl]
        if values == nil then
            _NGXVALS[tbl] = {
                [key] = value,
            }
        else
            values[key] = value
        end
    end,
}

setmetatable(ngx.var, var_mt)
setmetatable(ngx.arg, var_mt)
setmetatable(ngx.header, var_mt)
setmetatable(ngx.ctx, var_mt)

local profile = require("apisix.core.profile")
profile.apisix_home = "/usr/local/apisix/"

local runner = require("busted.runner")
runner(
    {
        standalone = false,
    }
)
