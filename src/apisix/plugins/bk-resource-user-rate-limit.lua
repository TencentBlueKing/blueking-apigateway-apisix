--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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
-- Rate limit verified users on resources requiring user authentication, across apps.
-- Authentication plugins populate ctx.var.bk_user before access. Other users are skipped.
-- rates.__default supplies the fallback; rates[username] replaces it for that user.
-- Later limiters can overwrite quota response headers when their header flag is enabled.
--
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")
local table_concat = table.concat
local ipairs = ipairs
local tostring = tostring

local plugin_name = "bk-resource-user-rate-limit"

local schema = {
    type = "object",
    properties = {
        rates = {
            type = "object",
            additionalProperties = {
                type = "array",
                items = {
                    type = "object",
                    properties = {
                        period = {type = "integer", minimum = 1},
                        tokens = {type = "integer", minimum = 1},
                    },
                    required = {"period", "tokens"},
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
}

local _M = {
    version = 0.1,
    priority = 17654,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    local resource_auth = ctx.var.bk_resource_auth
    if resource_auth == nil or not resource_auth:get_verified_user_required() then
        return
    end

    local bk_user = ctx.var.bk_user
    if bk_user == nil or bk_user.verified ~= true then
        return
    end

    local bk_username = bk_user.username
    if bk_username == nil or bk_username == "" then
        return
    end

    if conf.rates == nil or conf.rates["__default"] == nil then
        return
    end

    local rates = conf.rates[bk_username] or conf.rates["__default"]
    if #rates == 0 then
        return
    end

    -- Match resource-rate-limit's resource-name scope, with a separate plugin namespace.
    local key = table_concat({
        bk_username,
        ctx.var.bk_gateway_name,
        ctx.var.bk_stage_name,
        ctx.var.bk_resource_name,
    }, ":")

    for i, rate in ipairs(rates) do
        local limit_key = key
        if #rates > 1 then
            limit_key = key .. ":" .. tostring(i)
        end

        local code = ratelimit.rate_limit(
            conf, ctx, plugin_name, limit_key, rate.tokens, rate.period
        )
        if code then
            return errorx.exit_with_apigw_err(
                ctx, errorx.new_resource_strategy_rate_limit_restriction(), _M
            )
        end
    end
end


return _M
