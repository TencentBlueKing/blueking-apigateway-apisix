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
-- rate-limit-redis
--
-- Connect to redis and provide redis-based rate-limit function.
--
-- It gets redis configuration via plugin_attr bk-rate-limit, e.g.
-- plugin_attr:
--   bk-rate-limit:
--     redis_host: 127.0.0.1
--     redis_port: 6380
--     redis_password: blueking
--     redis_database: 0
--     redis_timeout: 1001
--
local pl_types = require("pl.types")
local redis_new = require("resty.redis").new
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local assert = assert
local setmetatable = setmetatable
local tostring = tostring

local _M = {
    version = 0.1,
}

local attr_schema = {
    type = "object",
    properties = {
        redis_host = {
            type = "string",
            minLength = 2,
        },
        redis_port = {
            type = "integer",
            minimum = 1,
            default = 6379,
        },
        redis_password = {
            type = "string",
            minLength = 0,
        },
        redis_database = {
            type = "integer",
            minimum = 0,
            default = 0,
        },
        redis_timeout = {
            type = "integer",
            minimum = 1,
            default = 1000,
        },
    },
}

local mt = {
    __index = _M,
}

local script = core.string.compress_script(
    [=[
    local ttl = redis.call('ttl', KEYS[1])
    if ttl < 0 then
        redis.call('set', KEYS[1], ARGV[1] - 1, 'EX', ARGV[2])
        return {ARGV[1] - 1, ARGV[2]}
    end
    return {redis.call('incrby', KEYS[1], -1), ttl}
]=]
)

-- maybe we can use https://github.com/go-redis/redis_rate/blob/v10/lua.go to support leaky-bucket

---@param conf table @plugin-attr configuration
local function redis_cli(conf)
    local red = redis_new()
    local timeout = conf.redis_timeout or 1000 -- 1sec

    -- set connect, send, and read to 1000ms, 1s
    red:set_timeouts(timeout, timeout, timeout)

    local ok, connect_err = red:connect(conf.redis_host, conf.redis_port or 6379)
    if not ok then
        return false, "failed to connect to redis, err: " .. connect_err
    end

    local count, check_err = red:get_reused_times()
    if 0 == count then
        if conf.redis_password and conf.redis_password ~= '' then
            local auth_ok, auth_err = red:auth(conf.redis_password)
            if not auth_ok then
                return nil, "failed to auth redis, err: " .. auth_err
            end
        end

        -- select db
        if conf.redis_database ~= 0 then
            local select_ok, select_err = red:select(conf.redis_database)
            if not select_ok then
                return false, "failed to change redis db, err: " .. select_err
            end
        end
    elseif check_err then
        return nil, "failed to check reused times, err: " .. check_err
    end
    return red, nil
end

---@param plugin_name string @apisix plugin name
function _M.new(plugin_name)
    local ratelimit_plugin_info = plugin.plugin_attr("bk-rate-limit") or {}
    local ok, err = core.schema.check(attr_schema, ratelimit_plugin_info)
    if not ok then
        core.log.error(
            "failed to check the plugin_attr[bk-rate-limit], err: ", err,
            "plugin: bk-rate-limit will not work, please check config.yaml: plugin_attr.bk-rate-limit"
        )
        ratelimit_plugin_info = {}
    end

    local self = {
        plugin_name = plugin_name,
        key_perfix = plugin_name .. ":",
        ratelimit_plugin_info = ratelimit_plugin_info,
    }
    return setmetatable(self, mt)
end

---@param key string @ratelimit key
---@param limit integer @ratelimit limit, an integer
---@param window integer @ratelimit time window, in seconds
function _M.incoming(self, key, limit, window)
    assert(limit > 0 and window > 0)

    if pl_types.is_empty(self.ratelimit_plugin_info) then
        return nil, "ratelimit_plugin_info is nil", 0
    end

    -- TODO: why here make the cli every time? should we put it into the self.red_cli?
    local red, err = redis_cli(self.ratelimit_plugin_info)
    if not red then
        return nil, "failed to new redis_cli, err: " .. err, 0
    end

    local res
    key = self.key_perfix .. tostring(key)

    local ttl = 0
    res, err = red:eval(script, 1, key, limit, window)
    if err then
        return nil, "failed to eval script, err: " .. err, ttl
    end

    local remaining = res[1]
    ttl = res[2]

    -- max_idle_timeout: ms, here set 5s
    -- pool_size: 75
    --   if 8 pods, 4 workers each; 8 * 4 * 75 = 2400 (currently)
    --   if 10 pods, 4 workers each; 10 * 4 * 75 = 3000
    --   if 12 pods, 4 workers each; 12 * 4 * 75 = 3600
    local ok, set_err = red:set_keepalive(5000, 75)
    if not ok then
        return nil, "failed to set keepalive, err: " .. set_err, ttl
    end

    if remaining < 0 then
        return nil, "rejected", ttl
    end
    return 0, remaining, ttl
end

if _TEST then -- luacheck: ignore
    _M._redis_cli = redis_cli
end

return _M
