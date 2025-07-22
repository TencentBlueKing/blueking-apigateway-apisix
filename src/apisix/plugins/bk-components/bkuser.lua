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

local GET_USER_URL = "/api/v3/apigw/tenant-users/%s/"
local BKUSER_TIMEOUT_MS = 3 * 1000

local bkapp = bk_core.config.get_bkapp() or {}

local err_status_404 = "status 404"

local function bkuser_do_request(host, path, params, request_id)
    if pl_types.is_empty(host) then
        return nil, "server error: bkuser host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(host, path)
    local res, err = bk_components_utils.handle_request(url, params, BKUSER_TIMEOUT_MS, false)
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

    -- 响应格式正常，错误码 404，表示应用不存在
    -- note: here we return an {} instead of err, because the lrucache should cache this result as well
    if res.status == 404 then
        return nil, err_status_404
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
            "failed to request third-party api, url: %s, request_id: %s, status: %s, response: %s, err: %s",
            url, request_id, res.status, res.body, err
        )
        core.log.error(new_err)
        return nil, new_err
    end

    return result, nil
end

local _M = {
    host = bk_core.config.get_bkuser_addr(),
    token = bk_core.config.get_bkuser_token(),
    app_code = bkapp.bk_app_code,
    app_secret = bkapp.bk_app_secret,
}

function _M.get_user_tenant_info(username)
    local path = string_format(GET_USER_URL, username)
    local request_id = uuid.generate_v4()
    local params = {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["X-Request-Id"] = request_id,
            ["Content-Type"] = "application/json",
            -- use bearer token to connect bkuser
            ["Authorization"] = "Bearer " .. _M.token,
        },
    }
    local result, err = bkuser_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        if err == err_status_404 then
            return { error_message="the user not exists" }, nil
        end
        return nil, err
    end

    -- data = {
    --
    -- }
    return {
        tenant_id=result.data.tenant_id,
        error_message=nil,
    }, nil
end


return _M