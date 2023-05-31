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
local bkauth_component = require("apisix.plugins.bk-components.bkauth")
local table_concat = table.concat

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
    return verify_app_secret_lrucache(key, nil, bkauth_component.verify_app_secret, app_code, app_secret)
end

function _M.list_app_secrets(app_code)
    local key = app_code
    local result = app_code_app_secrets_lrucache(key, nil, bkauth_component.list_app_secrets, app_code)
    return result.app_secrets, result.err
end

return _M
