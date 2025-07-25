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


-- verified the inner jwt token signed by bk-apigateway
-- X-Bkapi-Authorization: {"inner_jwt": ""}
-- currently it only be used in the mcp-proxy, which will proxy the request from agent to the real apigateway api
-- so, after the bk-apigateway verified the app and user, it generate the inner_jwt and call the real apigateway api
-- the app_code in inner_jwt is not the real app_code, but a virtual app_code(like v_mcp_{mcp_service_id}_{app_code})
-- so the permission can be controlled by the virtual app_code,
-- which not exists in the real PaaS, so no security concern.
-- NOTE: the design of verifier is not so good, so here we parse_bk_jwt_token twice
--       only refactor it if the performance is a problem

local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local jwt_utils = require("apisix.plugins.bk-auth-verify.jwt-utils")
local string_format = string.format
local setmetatable = setmetatable

local _M = {
    name = "inner-jwt",
}

local mt = {
    __index = _M,
}

function _M.new(inner_jwt_token)
    return setmetatable(
        {
            jwt_token = inner_jwt_token,
        }, mt
    )
end

function _M.verify_app(self)
    local jwt_obj, err = jwt_utils.parse_bk_jwt_token(self.jwt_token)
    if jwt_obj == nil then
        return nil, string_format("parameter jwt is invalid: %s", err)
    end

    if jwt_obj.header.kid ~= "bk-apigateway" then
        return nil, "invalid kid, only bk-apigateway is supported"
    end

    local app_info = jwt_obj.payload.app
    if app_info == nil then
        return nil, "parameter jwt does not indicate app information"
    end
    if app_info.verified ~= true then
        return nil, "the app indicated by jwt is not verified"
    end

    return bk_app_define.new_app(
        {
            app_code = app_info.app_code,
            exists = true,
            verified = true,
        }
    )
end

function _M.verify_user(self)
    local jwt_obj, err = jwt_utils.parse_bk_jwt_token(self.jwt_token)
    if jwt_obj == nil then
        return nil, string_format("parameter jwt is invalid: %s", err)
    end

    if jwt_obj.header.kid ~= "bk-apigateway" then
        return nil, "invalid kid, only bk-apigateway is supported"
    end

    local user_info = jwt_obj.payload.user
    if user_info == nil then
        return bk_user_define.new_anonymous_user(
        "auth parameter does not indicate user information, verified by inner-jwt-verifier"
        )
    end

    if user_info.verified ~= true then
        return bk_user_define.new_anonymous_user(
        "the user indicated by auth parameter is not verified, verified by inner-jwt-verifier"
        )
    end

    return bk_user_define.new_user(
        {
            username = user_info.username,
            verified = true,
            source_type = "inner_jwt",
        }
    )
end

return _M
