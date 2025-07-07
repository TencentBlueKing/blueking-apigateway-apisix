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

--
-- 这个模块使用 http 调用 apigateway-core 获取数据
-- 注意这里使用的是新版的 HTTP 协议(标准 HTTP 状态码 + response body 定义)
local core = require("apisix.core")
local uuid = require("resty.jit-uuid")
local bk_core = require("apisix.plugins.bk-core.init")
local string_format = string.format
local bk_components_utils = require("apisix.plugins.bk-components.utils")

local QUERY_PERMISSION_URL = "/api/v1/micro-gateway/%s/permissions/"
local QUERY_PUBLIC_KEY_URL = "/api/v1/micro-gateway/%s/public_keys/"
-- NOTE: important, if you change the timeout here, you should reset the timeout/exptime in bk-cache-fallback lock
local BKCORE_TIMEOUT_MS = 2480

local _M = {
    host = bk_core.config.get_bk_apigateway_core_addr(),
    instance_id = bk_core.config.get_instance_id(),
    instance_secret = bk_core.config.get_instance_secret(),
}

local function bk_apigateway_core_do_get(instance_id, instance_secret, host, path, query)
    -- ok: {
    --   "data": {}
    --}
    -- fail: {
    --   "error": {}
    -- }
    local url = bk_core.url.url_single_joining_slash(host, path)
    local request_id = uuid.generate_v4()
    -- send a request
    local params = {
        method = "GET",
        headers = {
            ["X-Bk-Micro-Gateway-Instance-Id"] = instance_id,
            ["X-Bk-Micro-Gateway-Instance-Secret"] = instance_secret,
            ["X-Request-Id"] = request_id,
        },
        query = query
    }
    local res, err = bk_components_utils.handle_request(url, params, BKCORE_TIMEOUT_MS, true)
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

    return result, nil
end

---@param gateway_name string @the name of the gateway
---@param resource_name string @the name of the resource
---@param app_code string @the name of the app_code
function _M.query_permission(gateway_name, stage_name, resource_name, app_code)
    -- query params: bk_gateway_name, bk_resource_name, bk_app_code
    -- response body:
    -- {
    --   "data": {
    --       "{bk_gateway_name}:-:{bk_app_code}": 1681897413,
    --       "{bk_gateway_name}:{bk_resource_name}:{bk_app_code}": 1681897413,
    --   }
    -- }

    local query = {
        bk_gateway_name = gateway_name,
        bk_stage_name = stage_name,
        bk_resource_name = resource_name,
        bk_app_code = app_code,
    }
    local path = string_format(QUERY_PERMISSION_URL, _M.instance_id)
    local result, err = bk_apigateway_core_do_get(_M.instance_id, _M.instance_secret, _M.host, path, query)
    if err ~= nil then
        core.log.error(err)
    end
    return result.data, err
end

---@param gateway_name string @the name of the gateway
function _M.get_apigw_public_key(gateway_name)
    -- query params: bk_gateway_name, bk_resource_name, bk_app_code
    -- response body:
    -- {
    --   "data": {
    --      "public_key": ""
    --   }
    -- }

    local query = {
        bk_gateway_name = gateway_name,
    }
    local path = string_format(QUERY_PUBLIC_KEY_URL, _M.instance_id)
    local result, err = bk_apigateway_core_do_get(_M.instance_id, _M.instance_secret, _M.host, path, query)
    if err ~= nil then
        core.log.error(err)
    end
    return result.data, err
end

return _M
