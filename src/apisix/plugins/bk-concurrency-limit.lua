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

-- bk-concurrency-limit
--
-- To implement concurrent rate limiting using the official limit-conn plugin,
-- increase the count using bk_concurrency_limit_key when a request comes in.
-- If the limit is exceeded, return a rate limiting error.
-- Otherwise, continue with the execution. During the logging phase, decrease the count to reduce computation.

local core = require("apisix.core")
local limiter = require("apisix.plugins.limit-conn.init")
local limit_conn = require("apisix.plugins.limit-conn")
local plugin = require("apisix.plugin")
local errorx = require("apisix.plugins.bk-core.errorx")
local table_concat = table.concat

local metadata_schema = core.table.deepcopy(limit_conn.schema)
local plugin_name = "bk-concurrency-limit"

local _M = {
    version = 0.1,
    priority = 17660,
    name = plugin_name,
    schema = {},
    metadata_schema = metadata_schema,
}

core.ctx.register_var(
    "bk_concurrency_limit_key", function(ctx)
        -- here we make the key for plugin bk-concurrency-limit(key type is `var`)
        -- will get a better performance instead of the regex operations if the key type is `var_combination`
        -- NOTE: the bk_app_code is empty if the gateway is no app-verified required, 2000 for each apisix instance
        --       maybe a problem in the future? should change to real-ip if the bk_app_code is empty?
        -- ANOTHER: change the bk_gateway_name to bk_gateway_id?

        local key = table_concat({
            ctx.var.bk_gateway_name,
            ctx.var.bk_stage_name,
            ctx.var.bk_app_code,
        }, ":")

        return key
    end
)

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    return true
end

function _M.access(conf, ctx)
    ---@type apisix.PluginMetadata
    local metadata = plugin.plugin_metadata(plugin_name)

    if not (metadata and metadata.value) then
        return
    end

    local code = limiter.increase(metadata.value, ctx)
    if not code then
        return
    end

    return errorx.exit_with_apigw_err(ctx, errorx.new_concurrency_limit_restriction(), _M)
end

function _M.log(conf, ctx)
    ---@type apisix.PluginMetadata
    local metadata = plugin.plugin_metadata(plugin_name)

    if not (metadata and metadata.value) then
        return
    end

    return limiter.decrease(metadata.value, ctx)
end

return _M
