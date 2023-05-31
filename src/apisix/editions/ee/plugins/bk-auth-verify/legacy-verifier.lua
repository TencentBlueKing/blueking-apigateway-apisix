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
local bk_core = require("apisix.plugins.bk-core.init")
local legacy_utils = require("apisix.plugins.bk-auth-verify.legacy-utils")
local setmetatable = setmetatable

local _M = {
    name = "legacy",
}

local mt = {
    __index = _M,
}

function _M.new(bk_app, bk_api_auth, auth_params)
    return setmetatable(
        {
            bk_app = bk_app,
            bk_api_auth = bk_api_auth,
            auth_params = auth_params,
        }, mt
    )
end

function _M.verify_app(self)
    if self.bk_api_auth:no_user_type() then
        return nil, "the gateway configuration error, please contact the API Gateway developer to handle"
    end

    return self.bk_app
end

function _M.verify_user(self)
    if self.bk_api_auth:no_user_type() then
        return nil, "the gateway configuration error, please contact the API Gateway developer to handle"
    end

    return self:verify_bk_user(self.bk_api_auth.user_conf)
end

function _M.verify_bk_user(self, user_conf)
    if user_conf.from_bk_token then
        local bk_token = self.auth_params:get_string("bk_token")
        if pl_types.is_empty(bk_token) then
            local bk_token_cookie = bk_core.cookie.get_value("bk_token")
            if not pl_types.is_empty(bk_token_cookie) then
                bk_token = bk_token_cookie
            end
        end
        if not pl_types.is_empty(bk_token) then
            return legacy_utils.verify_by_bk_token(bk_token)
        end
    end

    if user_conf.from_username then
        local username = self.auth_params:get_first_no_nil_string_from_two_keys("bk_username", "username")
        if not pl_types.is_empty(username) then
            return legacy_utils.verify_by_username(username)
        end
    end

    return nil,
           "user authentication failed, please provide a valid user identity, such as bk_username, bk_token, access_token" -- luacheck: ignore
end

return _M
