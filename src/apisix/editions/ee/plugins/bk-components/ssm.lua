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
local pl_types = require("pl.types")
local uuid = require("resty.jit-uuid")
local core = require("apisix.core")

local bk_core = require("apisix.plugins.bk-core.init")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

local string_format = string.format

local VERIFY_ACCESS_TOKEN_URL = "/api/v1/auth/access-tokens/verify"
local SSM_TIMEOUT_MS = 5 * 1000

local bkapp = bk_core.config.get_bkapp() or {}

local _M = {
    host = bk_core.config.get_ssm_addr(),
    app_code = bkapp.bk_app_code,
    app_secret = bkapp.bk_app_secret,
}

function _M.is_configured()
    return not pl_types.is_empty(_M.host)
end

local function ssm_do_request(host, path, params, request_id)
    if pl_types.is_empty(host) then
        return nil, "server error: ssm host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(host, path)
    local res, err = bk_components_utils.handle_request(url, params, SSM_TIMEOUT_MS, true)
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

    local result
    result, err = bk_components_utils.parse_response_json(res.body)
    if err ~= nil then
        local new_err = string_format(
            "failed to request third-party api, url: %s, request_id: %s, status: %s, response: %s, err: %s",
            url, request_id, res.status, res.body, err
        )
        core.log.error(new_err)
        return nil, new_err
    end

    if result.code ~= 0 then
        local new_err = string_format(
            "access_token is invalid, ssm error message: %s, request_id: %s, status: %s, result.code!=0, response: %s",
            url, request_id, res.status, res.body
        )
        core.log.error(new_err)
        return nil, new_err
    end

    return result, nil
end

function _M.verify_access_token(access_token)
    local request_id = uuid.generate_v4()
    local path = VERIFY_ACCESS_TOKEN_URL
    local params = {
        method = "POST",
        body = core.json.encode({
            access_token = access_token,
        }),
        ssl_verify = false,
        headers = {
            ["X-Bk-App-Code"] = _M.app_code,
            ["X-Bk-App-Secret"] = _M.app_secret,
            ["X-Request-Id"] = request_id,
            ["Content-Type"] = "application/json",
        },
    }
    local result, err = ssm_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        return nil, err
    end

    return {
        bk_app_code = result.data.bk_app_code,
        username = result.data.identity.username,
        expires_in = result.data.expires_in,
    }
end

return _M
