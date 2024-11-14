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
local bklogin_component = require("apisix.plugins.bk-components.bklogin")
local lru_new = require("resty.lrucache").new

local BK_TOKEN_CACHE_TTL = 300
local BK_TOKEN_CACHE_COUNT = 2000
local bk_token_lrucache = core.lrucache.new(
    {
        ttl = BK_TOKEN_CACHE_TTL,
        count = BK_TOKEN_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)

local BK_TOKEN_FALLBACK_CACHE_TTL = 60 * 60 * 24
local BK_TOKEN_FALLBACK_CACHE_COUNT = 2000
local bk_token_fallback_lrucache = lru_new(BK_TOKEN_FALLBACK_CACHE_COUNT)

local _M = {}

function _M.get_username_by_bk_token(bk_token)
    local key = bk_token
    local result, err = bk_token_lrucache(key, nil, bklogin_component.get_username_by_bk_token, bk_token)
    if result == nil then
        -- if the service is down(100% down), we can use the fallback cache, make the dp robust
        -- if the bklogin down, no new bk_token will be generated; but the old bk_token maybe expired
        if err == "connection refused" then
            -- try to use the fallback cache
            result = bk_token_fallback_lrucache:get(key)
            if result ~= nil then
                core.log.error("the bklogin down, error: ", err, " use the fallback cache. ",
                               "key=", key, " result=", core.json.delay_encode(result))
                return result.username, result.error_message
            end

            err = "get_username_by_bk_token failed, error: " .. err
        end

        return nil, err
    end

    -- if the service is ok, update the fallback cache, keep it the newest
    bk_token_fallback_lrucache:set(key, result, BK_TOKEN_FALLBACK_CACHE_TTL)

    return result.username, result.error_message
end

if _TEST then -- luacheck: ignore
    _M._bk_token_fallback_lrucache = bk_token_fallback_lrucache
end

return _M
