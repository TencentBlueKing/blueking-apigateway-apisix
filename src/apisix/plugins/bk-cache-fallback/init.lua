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
-- bk-cache-fallback
--
-- 这个模块主要逻辑:
-- 1. 使用 lrucache 做第一级缓存, lrucache 中不存在, 则调用后台接口, 获取数据
-- 2. 如果调用后台接口成功, 写 lrucache, ttl=60s, 会写一份数据到 shared_dict 中, ttl=1h
-- 3. 如果调用后台接口失败, 会尝试从 shared_dict 中获取数据(相当于 1 个小时内的快照)
-- 这么做的目的是:
-- 1. 提升整体的可用率, 避免因为依赖的核心服务出问题影响到正常代理的流量
-- 其他:
-- 1. 这是从官方lrucache模块代码修改而来
--
local core = require("apisix.core")
local resty_lock = require("resty.lock")
local log = require("apisix.core.log")
local lru_new = require("resty.lrucache").new
local tostring = tostring
local ngx = ngx
local ngx_shared = ngx.shared

local fallback_missing_err = "create_obj_funcs failed and got no data in the shared_dict for fallback"

-- NOTE: change to separate shared_dict, avoid use the name with `lurcache-lock`
local lock_shdict_name = "plugin-bk-cache-fallback-lock"
if ngx.config.subsystem == "stream" then
    lock_shdict_name = lock_shdict_name .. "-" .. ngx.config.subsystem
end

local GLOBAL_LRUCACHE_MAX_ITEMS = 1024
local GLOBAL_LRUCACHE_TTL = 60 -- 1 min
local GLOBAL_LRUCACHE_SHORT_TTL = 10 -- 10 seconds
local GLOBAL_FALLBACK_CACHE_TTL = 60 * 60 -- 1 hour

local _M = {
    name = "bk-cache-fallback",
}

local mt = {
    __index = _M,
}

function _M.new(conf, plugin_name)

    return setmetatable(
        {
            lrucache_max_items = conf.lrucache_max_items or GLOBAL_LRUCACHE_MAX_ITEMS,
            lrucache_ttl = conf.lrucache_ttl or GLOBAL_LRUCACHE_TTL,
            lrucache_short_ttl = conf.lrucache_short_ttl or GLOBAL_LRUCACHE_SHORT_TTL,
            fallback_cache_ttl = conf.fallback_cache_ttl or GLOBAL_FALLBACK_CACHE_TTL,

            plugin_name = plugin_name,
            plugin_name_with_colon = plugin_name .. ":",
            plugin_shared_dict_name = "plugin-" .. plugin_name,

            key_prefix = plugin_name .. ":",
        }, mt
    )
end

local lrucache = core.lrucache.new(
    {
        type = "plugin",
        serial_creating = true,
    }
)

local function create_lrucache_obj(plugin_name, max_items)
    core.log.info("create new lrucache for bk-cache-fallback plugin instance: " .. plugin_name)
    return lru_new(max_items)
end

--- get_with_fallback will get the key from lrucache first, if not found, will try to call create_obj_func to retrieve
--- the data, if create_obj_func successed, will set into both lrucache and shared_dict,
--- if create_obj_func failed, will try to get the data from shared_dict.
---@param ctx table @apisix context
---@param key string @cache key
---@param version string @cache version
---@param create_obj_func function @function for creating cache objects, should with a
---                                 reasonable timeout(avoid blocking the worker),
---                                 the return value type should be table
function _M.get_with_fallback(self, ctx, key, version, create_obj_func, ...)
    -- debugger()
    local lru_obj, err = core.lrucache.plugin_ctx(
        lrucache, ctx, self.plugin_name, create_lrucache_obj, self.plugin_name, self.lrucache_max_items
    )
    if not lru_obj then
        core.log.error("failed to get bk-cache-fallback lrucache object, err: ", err)
        return nil, err
    end

    local cache_key = self.key_prefix .. tostring(key)

    -- 1. lrucahce
    -- note here we do not care about stale_obj
    local cache_obj, _ = lru_obj:get(cache_key)

    -- 1.1 lrucache hit
    if cache_obj and cache_obj.ver == version then
        local cache_value = cache_obj.val
        if cache_value.err == fallback_missing_err then
            return nil, self.plugin_name_with_colon .. cache_value.err
        end

        return cache_obj.val, nil
    end
    -- 1.2 lrucache miss

    -- 2. retrieve the lock
    -- NOTE: while the bk-components http timeout is 5s, here the lock timeout should be bigger than 5s
    --       and at the same time, set the exptime shorter, the lock will be released if the worker is crashed
    --       so:  http timeout < lock timeout < lock exptime
    --       https://github.com/openresty/lua-resty-lock#new
    local lock, create_lock_err = resty_lock:new(lock_shdict_name, {timeout = 6, exptime = 7})
    if not lock then
        return nil, "failed to create lock, err: " .. create_lock_err
    end

    local key_s = cache_key
    log.info("try to lock with key ", key_s)

    -- NOTE: possible problem here, if high concurrent, all requests may wait here except one
    --        and at that time, process one by one after the retrieve finished, some requests will timeout?
    local elapsed, lock_err = lock:lock(key_s)
    if not elapsed then
        if lock_err ~= "timeout" then
            return nil, "failed to acquire the bk-cache-fallback lock, err: " .. lock_err
        end

        -- NOTE: 2024-11-11 we met some timeout here, in the same apisix pod, the same cache_key,
        --       the lock aquire timeout, then cause all responses fail at that time!
        -- So: we should try to use the fallback shared_dict data here
        local shared_data_dict = ngx_shared[self.plugin_shared_dict_name]
        if shared_data_dict ~= nil then
            local sd = shared_data_dict:get(cache_key)
            if sd ~= nil then
                local obj_decoded, json_err = core.json.decode(sd)
                if json_err == nil then
                    log.error("failed to acquire the bk-cache-fallback lock, fallback to get the data from shared_dict")
                    return obj_decoded, nil
                end
            end
        end

        return nil, "failed to acquire the bk-cache-fallback lock, error: timeout."
    end

    -- TODO: 函数过长, 需要考虑拆分, 特别是 unlock 特别多, 也容易出问题
    -- like: local ok, obj = pcall(foo) ...  lock.unlock()

    -- NOTE: from here, should release the lock before return

    -- 3. try get from lrucache again, maybe other worker has already updated the cache
    cache_obj, _ = lru_obj:get(cache_key)
    if cache_obj then
        lock:unlock()
        log.info("unlock with key ", key_s)
        return cache_obj.val
    end

    -- 4. fetch the data via create_obj_func

    -- 4.1 get shared_dict
    -- 全局锁, 所以每个插件一个shared_dict, 并且保持shared_dict体积尽量小, 避免全局锁冲突
    local shared_data_dict = ngx_shared[self.plugin_shared_dict_name]
    if shared_data_dict == nil then
        lock:unlock()
        log.info("unlock with key ", key_s)

        return nil, "failed to get shared_dict: " .. self.plugin_shared_dict_name
    end

    -- 4.2 call create_obj_func
    local obj, create_obj_err = create_obj_func(...)

    -- call create_obj_func success
    if create_obj_err == nil then
        lru_obj:set(
            cache_key, {
                val = obj,
                ver = version,
            }, self.lrucache_ttl
        )

        -- TODO: set failed: bad value type
        local obj_str, json_err = core.json.encode(obj)
        if json_err == nil then
            local ok, set_err, _ = shared_data_dict:set(cache_key, obj_str, self.fallback_cache_ttl)
            if not ok then
                core.log.error("shared_data_dict:set failed: ", set_err)
            end
        else
            core.log
                .error("shared_data_dict:set failed: the obj can not be encoded to json: ", json_err, ", obj: ", obj)
        end

        lock:unlock()
        log.info("unlock with key ", key_s)
        return obj, err
    else
        -- NOTE: we should not expose the real create_obj_err to the user
        --       it may contains some sensitive information
        core.log.error(
            self.plugin_name_with_colon, "call create_obj_func failed: ", create_obj_err,
            ", will fallback into getting the data from shared_dict"
        )
    end

    -- 4.3 call create_obj_func fail, will fallback to shared_dict

    -- read from shared_dict
    local sd = shared_data_dict:get(cache_key)

    -- 4.3.1 shared_dict hit
    if sd ~= nil then
        local obj_decoded, json_err = core.json.decode(sd)
        if json_err == nil then
            lru_obj:set(
                cache_key, {
                    val = obj_decoded,
                    ver = version,
                }, self.lrucache_ttl
            )

            lock:unlock()
            log.info("unlock with key ", key_s)
            return obj_decoded, nil
        else
            -- else, treat as shared_dict miss
            log.error("shared_data_dict:get failed: the obj can not be decoded from json: ", json_err, ", obj: ", sd)
        end
    end

    -- 4.3.2 shared_dict miss
    local err_data = {
        err = fallback_missing_err,
    }
    -- set into ttl with a short ttl, guard for call the create_obj_func in the next request
    lru_obj:set(
        cache_key, {
            val = err_data,
            ver = version,
        }, self.lrucache_short_ttl
    )

    lock:unlock()
    log.info("unlock with key ", key_s)
    return nil, self.plugin_name_with_colon .. fallback_missing_err
end

if _TEST then -- luacheck: ignore
    _M._GLOBAL_LRUCACHE_MAX_ITEMS = GLOBAL_LRUCACHE_MAX_ITEMS
    _M._GLOBAL_LRUCACHE_TTL = GLOBAL_LRUCACHE_TTL
    _M._GLOBAL_LRUCACHE_SHORT_TTL = GLOBAL_LRUCACHE_SHORT_TTL
    _M._GLOBAL_FALLBACK_CACHE_TTL = GLOBAL_FALLBACK_CACHE_TTL

    _M._fallback_missing_err = fallback_missing_err
    _M._create_lrucache_obj = create_lrucache_obj
end

return _M
