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
local uuid = require("resty.jit-uuid")
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")

local string_format = string.format
local table_insert = table.insert
local ipairs = ipairs

local VERIFY_APP_SECRET_URL = "/api/v1/apps/%s/access-keys/verify"
local LIST_APP_SECRETS_URL = "/api/v1/apps/%s/access-keys"
local GET_APP_URL = "/api/v1/apps/%s"

local BKAUTH_TIMEOUT_MS = 3 * 1000

local bkapp = bk_core.config.get_bkapp() or {}

local _M = {
    host = bk_core.config.get_bkauth_addr(),
    app_code = bkapp.bk_app_code,
    app_secret = bkapp.bk_app_secret,
    -- bkauth_access_token = bkapp.bkauth_access_token,
}

function _M.verify_app_secret(app_code, app_secret)
    if pl_types.is_empty(_M.host) then
        return nil, "server error: bkauth host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(_M.host, string_format(VERIFY_APP_SECRET_URL, app_code))

    local http_client = http.new()
    http_client:set_timeout(BKAUTH_TIMEOUT_MS)

    local request_id = uuid.generate_v4()
    local res, err = http_client:request_uri(
        url, {
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
    )

    -- if got timeout, retry here
    if err == "timeout" then
        res, err = http_client:request_uri(
            url, {
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
        )
    end

    if not (res and res.body) then
        local wrapped_err = string_format(
            "failed to request third-party api, url: %s, request_id: %s, err: %s, response: nil",
            url, request_id, err
        )
        core.log.error(wrapped_err)
        if err == "connection refused" then
            return nil, err
        end
        return nil, wrapped_err
    end

    -- 响应格式正常，错误码 404，表示应用不存在
    if res.status == 404 then
        return {
            existed = false,
            verified = false,
        }
    end

    local result = core.json.decode(res.body)
    if result == nil then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, response is not valid json, status: %s, response: %s",
                url, request_id, res.status, res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, response is not valid json, url: %s, request_id: %s, status: %s",
            url, request_id, res.status
        )
    end

    if result.code ~= 0 or res.status ~= 200 then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, result.code!=0 or status!=200, status: %s, response: %s",
                url, request_id, res.status, res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, bkauth error message: %s, url: %s, \
             request_id: %s, status: %s, code: %s",
            result.message, url, request_id, res.status, result.code
        )
    end

    return {
        existed = true,
        verified = result.data.is_match,
    }
end

function _M.list_app_secrets(app_code)
    if pl_types.is_empty(_M.host) then
        return nil, "server error: bkauth host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(_M.host, string_format(LIST_APP_SECRETS_URL, app_code))

    local http_client = http.new()
    http_client:set_timeout(BKAUTH_TIMEOUT_MS)
    local request_id = uuid.generate_v4()
    local res, err = http_client:request_uri(
        url, {
            method = "GET",
            ssl_verify = false,
            headers = {
                ["X-Bk-App-Code"] = _M.app_code,
                ["X-Bk-App-Secret"] = _M.app_secret,
                ["X-Request-Id"] = request_id,
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
        }
    )

    if not (res and res.body) then
        err = string_format("failed to request third-party api, url: %s, request_id: %s, err: %s, response: nil", url,
            request_id, err)
        core.log.error(err)
        return nil, err
    end

    -- 响应格式正常，错误码 404，表示应用不存在
    if res.status == 404 then
        return {
            app_secrets = {},
        }
    end

    local result = core.json.decode(res.body)
    if result == nil then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, response is not valid json, status: %s, response: %s", url,
                request_id, res.status, res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, response is not valid json, url: %s, request_id: %s, status: %s", url,
            request_id, res.status
        )
    end

    if result.code ~= 0 or res.status ~= 200 then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, result.code!=0 or status!=200, status: %s, response: %s", url,
                request_id, res.status,
                res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, bkauth error message: %s, url: %s,\
             request_id: %s, status: %s, code: %s",
            result.message, url, request_id, res.status, result.code
        )
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
    if pl_types.is_empty(_M.host) then
        return nil, "server error: bkauth host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(_M.host, string_format(GET_APP_URL, app_code))

    local http_client = http.new()
    http_client:set_timeout(BKAUTH_TIMEOUT_MS)

    local request_id = uuid.generate_v4()
    local res, err = http_client:request_uri(
        url, {
            method = "GET",
            ssl_verify = false,

            headers = {
                ["X-Bk-App-Code"] = _M.app_code,
                ["X-Bk-App-Secret"] = _M.app_secret,
                ["X-Request-Id"] = request_id,
                ["Content-Type"] = "application/json",
            },
        }
    )

    -- if got timeout, retry here
    if err == "timeout" then
        res, err = http_client:request_uri(
            url, {
                method = "GET",
                ssl_verify = false,

                headers = {
                    ["X-Bk-App-Code"] = _M.app_code,
                    ["X-Bk-App-Secret"] = _M.app_secret,
                    ["X-Request-Id"] = request_id,
                    ["Content-Type"] = "application/json",
                },
            }
        )
    end

    if not (res and res.body) then
        local wrapped_err = string_format(
            "failed to request third-party api, url: %s, request_id: %s, err: %s, response: nil",
            url, request_id, err
        )
        core.log.error(wrapped_err)
        if err == "connection refused" then
            return nil, err
        end
        return nil, wrapped_err
    end

    -- 响应格式正常，错误码 404，表示应用不存在
    -- note: here we return an {} instead of err, because the lrucache should cache this result as well
    if res.status == 404 then
        return {
            error_message="the app not exists"
        }, nil
    end

    local result = core.json.decode(res.body)
    if result == nil then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, response is not valid json, status: %s, response: %s",
                url, request_id, res.status, res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, response is not valid json, url: %s, request_id: %s, status: %s",
            url, request_id, res.status
        )
    end

    if result.code ~= 0 or res.status ~= 200 then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, result.code!=0 or status!=200, status: %s, response: %s",
                url, request_id, res.status, res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, bkauth error message: %s, url: %s, \
             request_id: %s, status: %s, code: %s",
            result.message, url, request_id, res.status, result.code
        )
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
        tenant_mode=result.data.tenant.mode,
        tenant_id=result.data.tenant.id,
        error_message=nil,
    }, nil
end


return _M