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
local uuid = require("resty.jit-uuid")
local pl_types = require("pl.types")
local core = require("apisix.core")

local bk_core = require("apisix.plugins.bk-core.init")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

local string_format = string.format

local VERIFY_BK_TOKEN_URL = "/api/v3/apigw/bk-tokens/verify/"

local BKLOGIN_TIMEOUT_MS = 5 * 1000

local _M = {
    host = bk_core.config.get_login_addr(),
}

local function bklogin_do_request(host, path, params, request_id)
    if pl_types.is_empty(host) then
        return nil, "server error: login host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(host, path)
    local res, err = bk_components_utils.handle_request(url, params, BKLOGIN_TIMEOUT_MS, true)
    if err ~= nil then
        -- if connection refused, return directly, without wrap(for the fallback cache upon layer)
        if err == "connection refused" then
            core.log.error("failed to request third-party api, url: %s, err: %s, response: nil", url, err)
            return nil, err
        end

        local new_err = string_format(
            "failed to request third-party api, url: %s, request_id: %s, err: %s",
            url, request_id, err
        )
        core.log.error(new_err)
        return nil, new_err
    end

    local result, _err = bk_components_utils.parse_response_json(res.body)
    if err ~= nil then
        local new_err = string_format(
            "failed to request third-party api, %s, request_id: %s, status: %s, response: %s, err: %s",
            url, request_id, res.status, res.body, _err
        )
        core.log.error(new_err)
        return nil, new_err
    end

    return result, nil
end

function _M.get_username_by_bk_token(bk_token)
    local request_id = uuid.generate_v4()
    local path = VERIFY_BK_TOKEN_URL
    local params = {
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

    local result, err = bklogin_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        return nil, err
    end

    if result.bk_error_code ~= 0 then
        return {
            error_message = string_format("bk_token is invalid,host: %s, path: %s, code: %s",
                                           _M.host, path, result.bk_error_code),
        }
    end

    return {
        username = result.data.bk_username,
    }
end

return _M
