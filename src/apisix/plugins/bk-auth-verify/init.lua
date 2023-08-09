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
local access_token_verifier = require("apisix.plugins.bk-auth-verify.access-token-verifier")
local jwt_verifier = require("apisix.plugins.bk-auth-verify.jwt-verifier")
local legacy_verifier = require("apisix.plugins.bk-auth-verify.legacy-verifier")
local bk_user_define = require("apisix.plugins.bk-define.user")
local setmetatable = setmetatable

local _M = {}

local mt = {
    __index = _M,
}

function _M.new(auth_params, bk_api_auth, bk_resource_auth)
    return setmetatable(
        {
            auth_params = auth_params,
            bk_api_auth = bk_api_auth,
            bk_resource_auth = bk_resource_auth,
        }, mt
    )
end

---@return table app
---@return boolean has_server_error There is an internal server error.
function _M.verify_app(self)
    local verifier = self:get_real_verifier()
    return verifier:verify_app()
end

---@return table user
---@return boolean has_server_error There is an internal server error.
function _M.verify_user(self)
    if self.bk_resource_auth:get_skip_user_verification() then
        return bk_user_define.new_anonymous_user(""), false
    end

    local verifier = self:get_real_verifier()
    local user, has_server_error = verifier:verify_user()

    -- complete rtx for uin user
    local uin_conf = self.bk_api_auth:get_uin_conf()
    if (not uin_conf:is_empty() and uin_conf.user_type == "uin" and uin_conf.search_rtx == true and
        not pl_types.is_empty(user:get_username())) then
        user:set_searched_rtx(uin_conf.search_rtx_source)
    end

    return user, has_server_error
end

function _M.get_real_verifier(self)
    local jwt_token = self.auth_params:get_string("jwt")
    local access_token = self.auth_params:get_string("access_token")

    if not pl_types.is_empty(jwt_token) then
        return jwt_verifier.new(jwt_token, access_token)

    elseif not pl_types.is_empty(access_token) then
        return access_token_verifier.new(access_token, self.auth_params)

    else
        return legacy_verifier.new(self.bk_api_auth, self.auth_params)

    end
end

return _M
