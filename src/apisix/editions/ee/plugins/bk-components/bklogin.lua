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

local IS_LOGIN_URL = "/login/api/v2/is_login/"

local BKLOGIN_TIMEOUT_MS = 5 * 1000

local _M = {
    host = bk_core.config.get_login_addr(),
}

function _M.get_username_by_bk_token(bk_token)
    if pl_types.is_empty(_M.host) then
        return nil, "server error: login host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(_M.host, IS_LOGIN_URL)

    local http_client = http.new()
    http_client:set_timeout(BKLOGIN_TIMEOUT_MS)
    local res, err = http_client:request_uri(
        url, {
            method = "GET",
            query = core.string.encode_args(
                {
                    bk_token = bk_token,
                }
            ),
            ssl_verify = false,
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
        }
    )

    local result, _err = bk_components_utils.parse_response(res, err, true)
    if result == nil then
        core.log.error(
            string_format(
                "failed to request %s, err: %s, status: %s, response: %s", url, _err, res and res.status,
                res and res.body
            )
        )
        return nil, string_format("failed to request third-party api, url: %s, err: %s", url, _err)
    end

    if result.bk_error_code ~= 0 then
        return {
            error_message = string_format("bk_token is invalid, code: %s", result.bk_error_code),
        }
    end

    return {
        username = result.data.bk_username,
    }
end

return _M
