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
local limit_redis_new = require("apisix.plugins.bk-rate-limit.rate-limit-redis").new
local lrucache = core.lrucache.new({
    type = 'plugin', serial_creating = true,
})

local _M = {
    app_limiter_schema = {
        type = "object",
        properties = {
            rates = {
                type = "object",
                additionalProperties = {
                    type = "array",
                    items = {
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
                },
            },
            allow_degradation = {
                type = "boolean",
                default = true
            },
            show_limit_quota_header = {
                type = "boolean",
                default = true
            },
        },
    },
}


local function create_limit_obj(plugin_name)
    core.log.info("create new limit-count plugin instance")
    -- maybe we can use https://github.com/ledgetech/lua-resty-redis-connector to support redis-sentinel
    return limit_redis_new("plugin-" .. plugin_name)
end

---@param conf table @apisix plugin configuration
---@param ctx table @apisix context
---@param plugin_name string @apisix plugin name
---@param key string @ratelimit key
---@param count string @ratelimit count, an integer
---@param time_window string @ratelimit time window, in seconds
function _M.rate_limit(conf, ctx, plugin_name, key, count, time_window)
    -- TODO: should all rate-limit plugin share the same redis connection pool? remove the plugin_name here?

    -- NOTE: you should always set the extra_key for each plugin, if not set, the key will always same for each request
    --       if use two rate_limit plugin, will get wrong lim!!!!!!
    local lim, err = core.lrucache.plugin_ctx(lrucache, ctx, plugin_name, create_limit_obj, plugin_name)

    if not lim then
        core.log.error("failed to fetch bk-limit-ratelimit object: ", err)
        if conf.allow_degradation then
            return
        end
        return 500
    end

    core.log.info("limit key: ", key)

    local delay, remaining, reset = lim:incoming(key, count, time_window)
    if not delay then
        err = remaining
        if err == "rejected" then
            -- show count limit header when rejected
            if conf.show_limit_quota_header then
                core.response.set_header("X-Bkapi-RateLimit-Limit", count,
                    "X-Bkapi-RateLimit-Remaining", 0,
                    "X-Bkapi-RateLimit-Reset", reset,
                    "X-Bkapi-RateLimit-Plugin", plugin_name)
            end

            return 429
        end

        core.log.error("failed to limit count: ", err)
        if conf.allow_degradation then
            return
        end
        return 500
    end

    if conf.show_limit_quota_header then
        core.response.set_header("X-Bkapi-RateLimit-Limit", count,
            "X-Bkapi-RateLimit-Remaining", remaining,
            "X-Bkapi-RateLimit-Reset", reset,
            "X-Bkapi-RateLimit-Plugin", plugin_name)
    end
end


return _M