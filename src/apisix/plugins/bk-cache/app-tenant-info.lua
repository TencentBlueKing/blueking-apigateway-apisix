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

local APP_TENANT_INFO_CACHE_TTL = 600
local APP_TENANT_INFO_CACHE_COUNT = 1000
local app_tenant_info_lrucache = core.lrucache.new(
    {
        ttl = APP_TENANT_INFO_CACHE_TTL,
        count = APP_TENANT_INFO_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)
local APP_TENANT_INFO_FALLBACK_CACHE_TTL = 60 * 60 * 24
local APP_TENANT_INFO_FALLBACK_CACHE_COUNT = 2000
local app_tenant_info_fallback_lrucache = lru_new(APP_TENANT_INFO_FALLBACK_CACHE_COUNT)


local _M = {}

function _M.get_app_tenant_info(app_code)
    local key = app_code

    local result, err = app_tenant_info_lrucache(key, nil, bkauth_component.get_app_tenant_info, app_code)
    if result == nil then
        -- if the service is down(100% down), we can use the fallback cache, make the dp robust
        if err == "connection refused" then
            -- try to use the fallback cache
            result = app_tenant_info_fallback_lrucache:get(key)
            if result ~= nil then
                core.log.error("the bkauth down, error: ", err, " use the fallback cache. ",
                               "key=", key, " result=", core.json.delay_encode(result))
                return result, result.error_message
            -- else
            --     core.log.error("the bkauth down, but also miss in fallback cache, error: ", err, " key=", key)
            end

            err = "get_app_tenant_info failed, error: " .. err
        end

        return nil, err
    end

    -- NOTE: here we don't know if the result is from the cache or the real request,
    --       so we update the fallback cache every time, which may not so efficient?
    app_tenant_info_fallback_lrucache:set(key, result, APP_TENANT_INFO_FALLBACK_CACHE_TTL)

    return result, result.error_message
end

if _TEST then -- luacheck: ignore
    _M._app_tenant_info_fallback_lrucache = app_tenant_info_fallback_lrucache
end

return _M

