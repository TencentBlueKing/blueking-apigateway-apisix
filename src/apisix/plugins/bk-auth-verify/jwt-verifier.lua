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

local access_token_utils = require("apisix.plugins.bk-auth-verify.access-token-utils")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local jwt_utils = require("apisix.plugins.bk-auth-verify.jwt-utils")
local string_format = string.format
local setmetatable = setmetatable

local _M = {
    name = "jwt",
}

local mt = {
    __index = _M,
}

function _M.new(jwt_token, access_token)
    return setmetatable(
        {
            jwt_token = jwt_token,
            access_token = access_token,
        }, mt
    )
end

function _M.verify_app(self)
    local token, err = access_token_utils.verify_access_token(self.access_token)
    if token == nil then
        return nil, err
    end

    return bk_app_define.new_app(
        {
            app_code = token:get_app_code(),
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

    local user_info = jwt_obj.payload.user
    if user_info == nil then
        return nil, "parameter jwt does not indicate user information"
    end

    if user_info.verified ~= true then
        return nil, "the user indicated by jwt is not verified"
    end

    return bk_user_define.new_user(
        {
            username = user_info.username,
            verified = true,
            source_type = "jwt",
        }
    )
end

return _M
