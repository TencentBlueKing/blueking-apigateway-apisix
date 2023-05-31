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
local bkauth_component = require("apisix.plugins.bk-components.bkauth")
local ssm_component = require("apisix.plugins.bk-components.ssm")

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

local _M = {}

local function get_access_token(access_token)
    local bkauth_token, err = bkauth_component.verify_access_token(access_token)
    if bkauth_token ~= nil then
        return {
            token = access_token_define.new(bkauth_token.bk_app_code, bkauth_token.username, bkauth_token.expires_in),
        }
    end

    if ssm_component.is_configured() then
        local ssm_token
        ssm_token, err = ssm_component.verify_access_token(access_token)
        if ssm_token ~= nil then
            return {
                token = access_token_define.new(ssm_token.bk_app_code, ssm_token.username, ssm_token.expires_in),
            }
        end
    end

    return {
        err = err,
    }
end

function _M.get_access_token(access_token)
    local key = access_token
    local result = access_token_lrucache(key, nil, get_access_token, access_token)
    return result.token, result.err
end

if _TEST then -- luacheck: ignore
    _M._get_access_token = get_access_token
end

return _M
