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
-- bk-stage-rate-limit
--
-- rate limit of app to the specified stage, with app dimension.
-- note: there is a special key `__default` in the rate-limit configuration,
--       it indicates the default rate-limit config of an app, and it should exist.
--
-- This plugin depends on:
--    * bk-rate-limit: The real logic for handling rate-limit
--    * bk-auth-verify: Get the verified bk_app_code
--
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")
local types = require("pl.types")
local table_concat = table.concat

local plugin_name = "bk-stage-rate-limit"

local _M = {
    version = 0.1,
    priority = 17652,
    name = plugin_name,
    schema = core.table.deepcopy(ratelimit.app_limiter_schema),
}

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end

---@param conf table @apisix plugin configuration
---@param ctx table @apisix context
function _M.access(conf, ctx)
    if types.is_empty(conf) then
        return
    end

    local bk_app_code = ctx.var.bk_app_code
    if bk_app_code == nil then
        return
    end

    if conf.rates == nil or conf.rates["__default"] == nil then
        return
    end

    -- TODO: make it lazy, share the key with other plugins
    local key = table_concat(
        {
            bk_app_code,
            ctx.var.bk_gateway_name,
            ctx.var.bk_stage_name,
            "-",
        }, ":"
    )

    local rates = conf.rates[bk_app_code] or conf.rates["__default"]

    if #rates == 0 then
        return
    elseif #rates == 1 then
        local rate = rates[1]
        local code = ratelimit.rate_limit(conf, ctx, plugin_name, key, rate.tokens, rate.period)
        if code then
            return errorx.exit_with_apigw_err(ctx, errorx.new_stage_strategy_rate_limit_restriction(), _M)
        else
            return
        end
    else
        for i, rate in ipairs(rates) do
            -- here we should add the rate index into key, otherwise the rate limit will be shared(will be wrong)
            -- FIXME: if the rate changes, will wait for the period to effect
            local limit_key = key .. ":" .. tostring(i)
            local code = ratelimit.rate_limit(conf, ctx, plugin_name, limit_key, rate.tokens, rate.period)
            if code then
                return errorx.exit_with_apigw_err(ctx, errorx.new_stage_strategy_rate_limit_restriction(), _M)
            end
        end

        return
    end

end

return _M
