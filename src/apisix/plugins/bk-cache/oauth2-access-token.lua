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
local core = require("apisix.core")
local bkauth_component = require("apisix.plugins.bk-components.bkauth")
local lru_new = require("resty.lrucache").new

local OAUTH2_ACCESS_TOKEN_CACHE_TTL = 300
local OAUTH2_ACCESS_TOKEN_CACHE_COUNT = 2000
local oauth2_access_token_lrucache = core.lrucache.new(
    {
        ttl = OAUTH2_ACCESS_TOKEN_CACHE_TTL,
        count = OAUTH2_ACCESS_TOKEN_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)

local OAUTH2_ACCESS_TOKEN_FALLBACK_CACHE_TTL = 60 * 60 * 24
local OAUTH2_ACCESS_TOKEN_FALLBACK_CACHE_COUNT = 2000
local oauth2_access_token_fallback_lrucache = lru_new(OAUTH2_ACCESS_TOKEN_FALLBACK_CACHE_COUNT)

local _M = {}


local function verify_oauth2_access_token(access_token)
    local result, err = bkauth_component.verify_oauth2_access_token(access_token)
    if result ~= nil then
        return {
            token = result,
        }, nil
    end

    return nil, err
end


---Get and verify an OAuth2 access token with caching
---@param access_token string The OAuth2 access token to verify
---@return table|nil result The verification result containing bk_app_code, bk_username, audience
---@return string|nil err The error message if verification failed
function _M.get_oauth2_access_token(access_token)
    local key = access_token
    local result, err = oauth2_access_token_lrucache(key, nil, verify_oauth2_access_token, access_token)
    if result == nil then
        -- if the service is down(100% down), we can use the fallback cache, make the dp robust
        if err == "connection refused" then
            -- try to use the fallback cache
            result = oauth2_access_token_fallback_lrucache:get(key)
            if result ~= nil then
                core.log.error("the bkauth down, error: ", err, " use the fallback cache. ",
                               "key=", key, " result=", core.json.delay_encode(result))
                return result.token, nil
            end

            err = "get_oauth2_access_token failed, error: " .. err
        end

        return nil, err
    end

    -- if the service is ok, update the fallback cache, keep it the newest
    oauth2_access_token_fallback_lrucache:set(key, result, OAUTH2_ACCESS_TOKEN_FALLBACK_CACHE_TTL)

    return result.token, nil
end


if _TEST then -- luacheck: ignore
    _M._verify_oauth2_access_token = verify_oauth2_access_token
    _M._oauth2_access_token_fallback_lrucache = oauth2_access_token_fallback_lrucache
end

return _M
