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
-- bk-stage-global-rate-limit
--
-- rate limit for stage, without app_code dimension, global for all apps
--
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")
local types = require("pl.types")
local table_concat = table.concat

local plugin_name = "bk-stage-global-rate-limit"

local _M = {
    version = 0.1,
    priority = 17651,
    name = plugin_name,
    schema = {
        type = "object",
        properties = {
            rate = {
                type = "object",
                properties = {
                    period = {
                        type = "integer",
                    },
                    tokens = {
                        type = "integer",
                    },
                },
            },
            allow_degradation = {
                type = "boolean",
                default = true,
            },
            show_limit_quota_header = {
                type = "boolean",
                default = true,
            },
        },
    },
}

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end

function _M.access(conf, ctx)
    if types.is_empty(conf) then
        return
    end

    -- TODO: make it lazy, share the key with other plugins
    local key = table_concat(
        {
            ctx.var.bk_gateway_name,
            ctx.var.bk_stage_name,
        }, ":"
    )

    local code = ratelimit.rate_limit(conf, ctx, plugin_name, key, conf.rate.tokens, conf.rate.period)
    if not code then
        return
    end

    return errorx.exit_with_apigw_err(ctx, errorx.new_stage_global_rate_limit_restriction(), _M)
end

return _M
