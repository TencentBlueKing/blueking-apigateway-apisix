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

-- # bk-repl-debugger
--
-- This is a debug tool for apisix, it will pause a request and start a repl console.
-- Do not use this plugin in production environment!!!
-- For safety reason, you should set the basic.enable in debug.yaml to enable this plugin.
-- and you should start apisix by this command:
-- openresty -p /usr/local/apisix -c /usr/local/apisix/conf/nginx.conf -g 'daemon off;'

local core = require("apisix.core")
local debug = require("apisix.debug")
local types = require("pl.types")

local schema = {
    type = "object",
    properties = {
        phases = {
            type = "array",
            items = {
                type = "string",
            },
        },
        enable_by_arg = {
            type = "boolean",
        },
    },
}

---@param conf table
---@param ctx apisix.Context
---@param phase? string
local function active_repl(conf, ctx, phase)
    if not debug.enable_debug() or types.is_empty(conf.phases) then
        return
    end

    if not phase then
        phase = ngx.get_phase()
    end

    local phase_matched = false
    for _, value in ipairs(conf.phases) do
        if value == phase then
            phase_matched = true
            break
        end
    end

    if not phase_matched then
        return
    end

    if conf.enable_by_arg and ctx.var["arg_repl"] ~= "1" then
        return
    end

    -- lua-resty-repl required
    require("resty.repl").start()
end

local _M = {
    version = 0.1,
    priority = 0,
    name = "bk-repl-debugger",
    schema = schema,
    before_each = active_repl,
    header_filter = active_repl,
    body_filter = active_repl,
    delayed_body_filter = active_repl,
    log = active_repl,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    active_repl(conf, ctx, "access")
end

function _M.rewrite(conf, ctx)
    active_repl(conf, ctx, "rewrite")
end

return _M
