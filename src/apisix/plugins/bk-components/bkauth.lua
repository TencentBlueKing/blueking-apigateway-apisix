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
local table_insert = table.insert
local ipairs = ipairs

local VERIFY_APP_SECRET_URL = "/api/v1/apps/%s/access-keys/verify"
local LIST_APP_SECRETS_URL = "/api/v1/apps/%s/access-keys"
local GET_APP_URL = "/api/v1/apps/%s"
local VERIFY_OAUTH2_ACCESS_TOKEN_URL = "/api/v1/oauth2/access-tokens/verify"

local BKAUTH_TIMEOUT_MS = 5 * 1000

local bkapp = bk_core.config.get_bkapp() or {}

local err_status_404 = "status 404"

local _M = {
    host = bk_core.config.get_bkauth_addr(),
    app_code = bkapp.bk_app_code,
    app_secret = bkapp.bk_app_secret,
    -- bkauth_access_token = bkapp.bkauth_access_token,
}

local function bkauth_do_request(host, path, params, request_id)
    if pl_types.is_empty(host) then
        return nil, "server error: bkauth host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(host, path)
    local res, err = bk_components_utils.handle_request(url, params, BKAUTH_TIMEOUT_MS, false)
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

    if result.code ~= 0 then
        local new_err = string_format(
                "failed to request third-party api, url: %s, request_id: %s, result.code!=0, status: %s, response: %s",
                url, request_id, res.status, res.body
        )
        core.log.error(new_err)
        return nil, new_err
    end

    return result, nil
end

function _M.verify_app_secret(app_code, app_secret)
    local request_id = uuid.generate_v4()
    local path = string_format(VERIFY_APP_SECRET_URL, app_code)
    local params = {
            method = "POST",
            body = core.json.encode(
                {
                    bk_app_secret = app_secret,
                }
            ),
            ssl_verify = false,

            headers = {
                ["X-Bk-App-Code"] = _M.app_code,
                ["X-Bk-App-Secret"] = _M.app_secret,
                ["X-Request-Id"] = request_id,
                ["Content-Type"] = "application/json",
            },
    }
    local result, err = bkauth_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        -- as cached data, we should return {} instead of err
        if err == err_status_404 then
            return { existed = false, verified = false }, nil
        end
        return nil, err
    end

    return {
        existed = true,
        verified = result.data.is_match,
    }
end

function _M.list_app_secrets(app_code)
    local path = string_format(LIST_APP_SECRETS_URL, app_code)
    local request_id = uuid.generate_v4()
    local params = {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["X-Bk-App-Code"] = _M.app_code,
            ["X-Bk-App-Secret"] = _M.app_secret,
            ["X-Request-Id"] = request_id,
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
    }
    local result, err = bkauth_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        -- as cached data, we should return {} instead of err
        if err == err_status_404 then
            return { app_secrets = {} }, nil
        end
        return nil, err
    end

    local app_secrets = {}
    for _, app in ipairs(result.data) do
        table_insert(app_secrets, app.bk_app_secret)
    end

    return {
        app_secrets = app_secrets,
    }
end

function _M.get_app_tenant_info(app_code)
    local request_id = uuid.generate_v4()
    local path = string_format(GET_APP_URL, app_code)
    local params = {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["X-Bk-App-Code"] = _M.app_code,
            ["X-Bk-App-Secret"] = _M.app_secret,
            ["X-Request-Id"] = request_id,
            ["Content-Type"] = "application/json",
        },
    }
    local result, err = bkauth_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        -- as cached data, we should return {} instead of err
        if err == err_status_404 then
            return { error_message="the app not exists" }, nil
        end
        return nil, err
    end
    -- data = {
    --     "app_code": "demo",
    --     "name": "demo",
    --     "description": "xxxx",
    --     "tenant": {
    --         "mode": "single",
    --         "id": "hello"
    --     }
    -- }
    return {
        tenant_mode=result.data.bk_tenant.mode,
        tenant_id=result.data.bk_tenant.id,
        error_message=nil,
    }, nil
end


---Verify an OAuth2 access token via bkauth service
---@param access_token string The OAuth2 access token to verify
---@return table|nil result The verification result containing bk_app_code, bk_username, audience
---@return string|nil err The error message if verification failed
function _M.verify_oauth2_access_token(access_token)
    local request_id = uuid.generate_v4()
    local path = VERIFY_OAUTH2_ACCESS_TOKEN_URL
    local params = {
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
            ["X-Request-Id"] = request_id,
            ["Content-Type"] = "application/json",
        },
    }
    local result, err = bkauth_do_request(_M.host, path, params, request_id)
    if err ~= nil then
        return nil, err
    end

    -- TODO:
    -- 1. what if it expired?
    -- 2. what if it is invalid?
    -- we should make it cacheable for invalid tokens

    -- response: {"data": {"bk_app_code": "...", "bk_username": "...", "audience": [...]}}
    return {
        bk_app_code = result.data.bk_app_code,
        bk_username = result.data.bk_username,
        audience = result.data.audience or {},
    }, nil
end


return _M