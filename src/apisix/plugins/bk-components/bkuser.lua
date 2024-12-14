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

-- FIXME: change to api/v3
local GET_USER_URL = "/api/v2/profiles/%s"

local BKAUTH_TIMEOUT_MS = 3 * 1000

local bkapp = bk_core.config.get_bkapp() or {}

local _M = {
    host = bk_core.config.get_bkuser_addr(),
    app_code = bkapp.bk_app_code,
    app_secret = bkapp.bk_app_secret,
}

function _M.get_user_tenant_info(app_code)
    if pl_types.is_empty(_M.host) then
        return nil, "server error: bkuser host is not configured."
    end

    local url = bk_core.url.url_single_joining_slash(_M.host, string_format(GET_USER_URL, app_code))

    local http_client = http.new()
    http_client:set_timeout(BKAUTH_TIMEOUT_MS)

    local request_id = uuid.generate_v4()
    local params = {
            method = "GET",
            ssl_verify = false,

            headers = {
                ["X-Request-Id"] = request_id,
                ["Content-Type"] = "application/json",
            },
    }
    local res, err = http_client:request_uri(url, params)

    -- if got timeout, retry here
    if err == "timeout" then
        res, err = http_client:request_uri(url, params)
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
            error_message="the user not exists"
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

    -- FIXME: api/v3 would not check result.code
    if result.code ~= 0 or res.status ~= 200 then
        core.log.error(
            string_format(
                "failed to request %s, request_id: %s, result.code!=0 or status!=200, status: %s, response: %s",
                url, request_id, res.status, res.body
            )
        )
        return nil, string_format(
            "failed to request third-party api, bkuser error message: %s, url: %s, \
             request_id: %s, status: %s, code: %s",
            result.message, url, request_id, res.status, result.code
        )
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