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
local uuid = require("resty.jit-uuid")
local pl_types = require("pl.types")
local core = require("apisix.core")

local bk_core = require("apisix.plugins.bk-core.init")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

local string_format = string.format

local LEGACY_VERIFY_BK_TOKEN_URL  = "/login/api/v2/is_login/"
local VERIFY_BK_TOKEN_URL = "/login/api/v3/apigw/bk-tokens/verify/"


local BKLOGIN_TIMEOUT_MS = 5 * 1000

local err_status_400 = "status 400, bk_token is not valid"

local _M = {
    host = bk_core.config.get_login_addr(),
    token = bk_core.config.get_login_token(),
    enable_multi_tenant_mode = bk_core.config.get_enable_multi_tenant_mode(),
}

local function bklogin_do_request(host, path, params, request_id)
    if pl_types.is_empty(host) then
        return nil, "server error: login host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(host, path)
    local res, err = bk_components_utils.handle_request(url, params, BKLOGIN_TIMEOUT_MS, false)
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

    -- 响应格式正常，错误码 400，表示 bk_token 非法
    -- note: here we return an {} instead of err, because the lrucache should cache this result as well
    if res.status == 400 then
        return nil, err_status_400
    end

    if res.status ~= 200 then
        local new_err = string_format(
                "failed to request third-party api, url: %s, request_id: %s, status!=200, status: %s, response: %s",
                url, request_id, res.status, res.body
            )
        core.log.error(new_err)
        return nil, new_err
    end

    local result
    result, err = bk_components_utils.parse_response_json(res.body)
    if err ~= nil then
        local new_err = string_format(
            "failed to request third-party api, %s, request_id: %s, status: %s, response: %s, err: %s",
            url, request_id, res.status, res.body, err
        )
        core.log.error(new_err)
        return nil, new_err
    end

    return result, nil
end

function _M.get_username_by_bk_token(bk_token)
    local request_id = uuid.generate_v4()
    local path = LEGACY_VERIFY_BK_TOKEN_URL
    if _M.enable_multi_tenant_mode then
        path = VERIFY_BK_TOKEN_URL
    end

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
                -- use bearer token to connect bklogin
                ["Authorization"] = "Bearer " .. _M.token,
            },
    }

    local result, err = bklogin_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        if err == err_status_400 then
            return {error_message="bk_token is not valid"}, nil
        end

        return nil, err
    end
    -- {"data": {"bk_username": "cpyjg3xo3ta0op6t", "tenant_id": "system"}}

    return {
        username = result.data.bk_username,
    }, nil
end

return _M

