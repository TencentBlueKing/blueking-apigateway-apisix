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

local core = require("apisix.core")
local http = require("resty.http")
local string_format = string.format
local uuid = require("resty.jit-uuid")


-- parse the response body, for te only
-- @param res: the response object
-- @param err: the error message
-- @param raise_for_status: if raise_for_status is true, then raise error when status is not 200
-- @return: the parsed response body or nil, the error
local function parse_response(res, err, raise_for_status)
    if not (res and res.body) then
        return nil, err
    end

    if raise_for_status and res.status ~= 200 then
        return nil, "status code is " .. res.status
    end

    local result, _err = core.json.decode(res.body)
    if _err ~= nil then
        return nil, "response is not valid json"
    end

    return result
end

-- handle the request, only ee use it
-- @param url: the request url
-- @param params: the request params
-- @param timeout: the request timeout
-- @param raise_for_status: if raise_for_status is true, then raise error when status is not 200
-- @return: the response object or nil, the error
local function handle_request(url, params, timeout, raise_for_status)
    -- new client
    local client = http.new()
    client:set_timeout(timeout or 5000)

    -- set request_id into params.headers, if not exists
    if not params.headers then
        params.headers = {
            ["X-Request-Id"] = uuid.generate_v4(),
            ["Content-Type"] = "application/json",
        }
    else
        if not params.headers["X-Request-Id"] then
            params.headers["X-Request-Id"] = uuid.generate_v4()
        -- else
        --     request_id = params.headers["X-Request-Id"]
        end
    end

    -- call the api
    local res, err = client:request_uri(url, params)

    -- if timeout/closed/connection reset by peer, retry
    if err == "timeout" or err == "closed" or err == "connection reset by peer" then
        res, err = client:request_uri(url, params)
    end

    -- if connection refused, return directly, without wrap(for the fallback cache upon layer)
    if err == "connection refused" then
        return nil, err
    end

    if not res then
        return nil, err .. ", response: nil"
    end

    if raise_for_status and  res.status ~= ngx.HTTP_OK then
        return nil, string_format("status is %s, not 200", res.status)
    end

    return res, nil
end

-- parse the response body, only ee use it
-- @param body: the response body
-- @return: the parsed response body or nil, the error
local function parse_response_json(body)
    if body == nil then
        return nil, "response body is empty"
    end

    local result, _err = core.json.decode(body)
    if _err ~= nil then
        return nil, "response is not valid json"
    end

    return result, nil
end

return {
    parse_response = parse_response,
    handle_request = handle_request,
    parse_response_json = parse_response_json,
}
