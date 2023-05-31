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
local bk_apigateway_core_component = require("apisix.plugins.bk-components.bk-apigateway-core")

local JWT_PUBLIC_KEY_CACHE_TTL = 600
local JWT_PUBLIC_KEY_CACHE_COUNT = 1000
local jwt_public_key_lrucache = core.lrucache.new(
    {
        ttl = JWT_PUBLIC_KEY_CACHE_TTL,
        count = JWT_PUBLIC_KEY_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)

local _M = {}

function _M.get_jwt_public_key(gateway_name)
    local key = gateway_name
    local result = jwt_public_key_lrucache(key, nil, bk_apigateway_core_component.get_apigw_public_key, gateway_name)
    if result == nil then
        return nil, "get_jwt_public_key of " .. gateway_name .. " failed"
    end
    return result.public_key, result.err
end

return _M
