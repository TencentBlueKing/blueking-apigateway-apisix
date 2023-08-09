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
local pl_types = require("pl.types")
local http = require("resty.http")
local core = require("apisix.core")

local bk_core = require("apisix.plugins.bk-core.init")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

local string_format = string.format

local VERIFY_ACCESS_TOKEN_URL = "/api/v1/auth/access-tokens/verify"
local SSM_TIMEOUT_MS = 5 * 1000

local bkapp = bk_core.config.get_bkapp()

local _M = {
    host = bk_core.config.get_ssm_addr(),
    app_code = bkapp.bk_app_code,
    app_secret = bkapp.bk_app_secret,
}

function _M.is_configured()
    return not pl_types.is_empty(_M.host)
end

---@param access_token string
---@return table|nil result Request result, if there is a request error, it should be nil. e.g.
---        {
---            "bk_app_code": "test",
---            "username": "admin",
---            "expires_in": 600
---        }
---@return string|nil err Request error
function _M.verify_access_token(access_token)
    if pl_types.is_empty(_M.host) then
        return nil, "ssm host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(_M.host, VERIFY_ACCESS_TOKEN_URL)

    local http_client = http.new()
    http_client:set_timeout(SSM_TIMEOUT_MS)
    local res, err = http_client:request_uri(
        url, {
            method = "POST",
            body = core.json.encode(
                {
                    access_token = access_token,
                }
            ),
            ssl_verify = false,
            headers = {
                ["X-Bk-App-Code"] = _M.app_code,
                ["X-Bk-App-Secret"] = _M.app_secret,
                ["Content-Type"] = "application/json",
            },
        }
    )

    local result, _err = bk_components_utils.parse_response(res, err, true)
    if result == nil then
        core.log.error(string_format("failed to request %s, err: %s", url, _err))
        return nil, string_format("failed to request %s, %s", url, _err)
    end

    if result.code ~= 0 then
        return {
            error_message = string_format("ssm error message: %s", result.message),
        }
    end

    return {
        bk_app_code = result.data.bk_app_code,
        username = result.data.identity.username,
        expires_in = result.data.expires_in,
    }
end

return _M
