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

local busted = require("busted")
local busted_resty = require("busted_resty")
local debugger = require("debugger")
local match = require("luassert.match")
local core = require("apisix.core")
local repl = require("resty.repl")

rawset(_G, "repl", repl.start)
rawset(_G, "debugger", debugger)
rawset(_G, "MATCH", match)
rawset(_G, "_TEST", true)

busted.subscribe(
    {
        "test",
        "end",
    }, function()
        busted_resty.clear()
        core.table.clear(_NGXVALS)
    end
)

math.randomseed(os.clock() * 100000000000)

-- generate a random integer
---@param min? integer @string minimum value
---@param max? integer @string maximum value
---@return integer
function RANDINT(min, max) -- luacheck: ignore
    if min == nil then
        min = 1
    end

    if max == nil then
        max = 100
    end

    return math.random(min, max)
end

-- generate a random string
---@param size? number @string size
---@return string
function RANDSTR(size) -- luacheck: ignore
    if size == nil then
        size = 8
    end

    local strs = {}
    for i = 1, size do
        strs[i] = string.char(math.random(97, 122))
    end

    return table.concat(strs)
end

---@param var? table<string, any>
---@return apisix.Context
function CTX(var) -- luacheck: ignore
    local ctx = {
        route_id = RANDSTR(),
        conf_type = "mock",
        conf_version = 0,
        conf_id = RANDINT(),
    }
    ngx.ctx.api_ctx = ctx

    core.ctx.set_vars_meta(ctx)

    if var ~= nil then
        for key, value in pairs(var) do
            ctx.var[key] = value
        end
    end

    return ctx
end
