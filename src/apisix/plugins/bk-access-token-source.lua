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
-- # bk-access-token-source
--
-- This plugin read the bearer token or X-API-KEY from the request header,
-- and set the token to the `access_token` field of the X-Bkapi-Authorization header.
-- note if the X-Bkapi-Authorization header is already set, this plugin will overwrite it.
--
-- This plugin would return 400 if there got no expected token in the request header.
--

local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local sub_str = string.sub

local plugin_name = "bk-access-token-source"

local BKAPI_AUTHORIZATION_HEADER = "X-Bkapi-Authorization"

local schema = {
    type = "object",
    properties = {
        source = {
            type = "string",
            enum = {"bearer", "api_key"},
            default = "bearer",
            description = "The source of the authentication token, default is bearer",
        }
    },
}


-- global config.yaml
local _M = {
    version = 0.1,
    priority = 18735,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_bearer_token(ctx)
    local value = core.request.header(ctx, "Authorization")
    if value == nil then
        return nil, "No `Authorization` header found in the request"
    end

    local prefix = sub_str(value, 1, 7)
    if prefix == 'Bearer ' or prefix == 'bearer ' then
        local token = sub_str(value, 8)
        return token, nil
    end

    return nil, "The `Authorization` header is not a bearer token"
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    local token
    if conf.source == "bearer" then
        local err
        token, err = get_bearer_token(ctx)
        if err then
            return errorx.exit_with_apigw_err(ctx, errorx.new_invalid_args():with_field("reason", err), _M)
        end
    elseif conf.source == "api_key" then
        token = core.request.header(ctx, "X-API-KEY")
        if token == nil then
            return errorx.exit_with_apigw_err(ctx,
            errorx.new_invalid_args():with_field("reason", "No `X-API-KEY` header found in the request"), _M)
        end
    end

    local encoded_token = core.json.encode({
        access_token = token,
    })
    core.request.set_header(ctx, BKAPI_AUTHORIZATION_HEADER, encoded_token)
end

if _TEST then -- luacheck: ignore
    _M._get_bearer_token = get_bearer_token
end

return _M
