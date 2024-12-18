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
local access_token_define = require("apisix.plugins.bk-define.access-token")
local ssm_component = require("apisix.plugins.bk-components.ssm")
local lru_new = require("resty.lrucache").new

local ACCESS_TOKEN_CACHE_TTL = 600
local ACCESS_TOKEN_CACHE_COUNT = 2000
local access_token_lrucache = core.lrucache.new(
    {
        ttl = ACCESS_TOKEN_CACHE_TTL,
        count = ACCESS_TOKEN_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)

local ACCESS_TOKEN_FALLBACK_CACHE_TTL = 60 * 60 * 24
local ACCESS_TOKEN_FALLBACK_CACHE_COUNT = 2000
local access_token_fallback_lrucache = lru_new(ACCESS_TOKEN_FALLBACK_CACHE_COUNT)

local _M = {}

local function get_access_token(access_token)
    local err

    if ssm_component.is_configured() then
        local ssm_token
        ssm_token, err = ssm_component.verify_access_token(access_token)
        if ssm_token ~= nil then
            return {
                token = access_token_define.new(ssm_token.bk_app_code, ssm_token.username, ssm_token.expires_in),
            }, nil
        end

        return nil, err
    end

    err = "authentication based on access_token is not supported"
    return nil, err
end

function _M.get_access_token(access_token)
    local key = access_token
    local result, err = access_token_lrucache(key, nil, get_access_token, access_token)
    if result == nil then
        -- if the service is down(100% down), we can use the fallback cache, make the dp robust
        if err == "connection refused" then
            -- try to use the fallback cache
            result = access_token_fallback_lrucache:get(key)
            if result ~= nil then
                core.log.error("the ssm down, error: ", err, " use the fallback cache. ",
                               "key=", key, " result=", core.json.delay_encode(result))
                return result.token, nil
            end

            err = "get_access_token failed, error: " .. err
        end

        return nil, err
    end

    -- if the service is ok, update the fallback cache, keep it the newest
    -- currently, the access_token(ee) is 24 hours, so the expires_in < 24 hours, and maybe the expires_in < 0
    local expires_in = result.token:get_expires_in()
    if expires_in > 0 and expires_in <= ACCESS_TOKEN_FALLBACK_CACHE_TTL then
        -- if the access_token will expire in 24 hours, set the ttl shorter,
        -- otherwise, when ssm down, some access_token will valid even it's already expired
        access_token_fallback_lrucache:set(key, result, expires_in)
    else
        -- if expires_in < 0, also set 24 hours ttl
        access_token_fallback_lrucache:set(key, result, ACCESS_TOKEN_FALLBACK_CACHE_TTL)
    end


    return result.token, nil
end

if _TEST then -- luacheck: ignore
    _M._get_access_token = get_access_token
    _M._access_token_fallback_lrucache = access_token_fallback_lrucache
end

return _M
