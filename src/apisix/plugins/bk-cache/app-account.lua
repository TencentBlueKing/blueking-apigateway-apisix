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
local table_concat = table.concat
local lru_new = require("resty.lrucache").new

local VERIFY_APP_SECRET_CACHE_TTL = 600
local VERIFY_APP_SECRET_CACHE_COUNT = 1000
local verify_app_secret_lrucache = core.lrucache.new(
    {
        ttl = VERIFY_APP_SECRET_CACHE_TTL,
        count = VERIFY_APP_SECRET_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)
local VERIFY_APP_SECRET_FALLBACK_CACHE_TTL = 60 * 60 * 24
local VERIFY_APP_SECRET_FALLBACK_CACHE_COUNT = 2000
local verify_app_secret_fallback_lrucache = lru_new(VERIFY_APP_SECRET_FALLBACK_CACHE_COUNT)

local APP_CODE_APP_SECRETS_CACHE_TTL = 600
local APP_CODE_APP_SECRETS_CACHE_COUNT = 1000
local app_code_app_secrets_lrucache = core.lrucache.new(
    {
        ttl = APP_CODE_APP_SECRETS_CACHE_TTL,
        count = APP_CODE_APP_SECRETS_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)

local _M = {}

function _M.verify_app_secret(app_code, app_secret)
    local key = table_concat(
        {
            app_code,
            app_secret,
        }, ":"
    )
    local result, err = verify_app_secret_lrucache(key, nil, bkauth_component.verify_app_secret, app_code, app_secret)
    if result == nil then
        -- if the service is down(100% down), we can use the fallback cache, make the dp robust
        if err == "connection refused" then
            -- try to use the fallback cache
            result = verify_app_secret_fallback_lrucache:get(key)
            if result ~= nil then
                core.log.error("the bkauth down, error: ", err, " use the fallback cache. ",
                               "key=", key, " result=", core.json.delay_encode(result))
                return result, nil
            -- else
            --     core.log.error("the bkauth down, but also miss in fallback cache, error: ", err, " key=", key)
            end

            err = "verify_app_secret failed, error: " .. err
        end

        return nil, err
    end

    -- if the service is ok, update the fallback cache, keep it the newest
    -- if the app_code/app_secret been updated, the service is ok, then the data in the fallback cache would be updated

    -- NOTE: here we don't know if the result is from the cache or the real request,
    --       so we update the fallback cache every time, which may not so efficient?
    verify_app_secret_fallback_lrucache:set(key, result, VERIFY_APP_SECRET_FALLBACK_CACHE_TTL)

    return result, err
end

function _M.list_app_secrets(app_code)
    local key = app_code
    return app_code_app_secrets_lrucache(key, nil, bkauth_component.list_app_secrets, app_code)
end

if _TEST then -- luacheck: ignore
    _M._verify_app_secret_fallback_lrucache = verify_app_secret_fallback_lrucache
end

return _M

