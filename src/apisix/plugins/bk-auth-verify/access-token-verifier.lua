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
local access_token_utils = require("apisix.plugins.bk-auth-verify.access-token-utils")
local app_account_verifier = require("apisix.plugins.bk-auth-verify.app-account-verifier")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local setmetatable = setmetatable

local _M = {
    name = "access_token",
}

local mt = {
    __index = _M,
}

function _M.new(access_token, auth_params)
    return setmetatable(
        {
            access_token = access_token,
            auth_params = auth_params,
        }, mt
    )
end

---@return table app
---@return boolean has_server_error There is an internal server error.
function _M.verify_app(self)
    local token, err, is_server_error = access_token_utils.verify_access_token(self.access_token)
    if token ~= nil then
        return bk_app_define.new_app(
            {
                app_code = token:get_app_code(),
                exists = true,
                verified = true,
            }
        ), false
    end

    -- 兼容 app_code + app_secret 校验
    local app = app_account_verifier.new(self.auth_params):verify_app()
    if app ~= nil and app:is_verified() then
        return app, false
    end

    return bk_app_define.new_anonymous_app(err), is_server_error or false
end

---@return table user
---@return boolean has_server_error There is an internal server error.
function _M.verify_user(self)
    local token, err, is_server_error = access_token_utils.verify_access_token(self.access_token)
    if token == nil then
        return bk_user_define.new_anonymous_user(err), is_server_error or false
    end

    if not token:is_user_token() then
        return
            bk_user_define.new_anonymous_user("the access_token is the application type and cannot indicate the user"),
            false
    end

    return bk_user_define.new_user(
        {
            username = token:get_user_id(),
            verified = true,
            source_type = "access_token",
        }
    ), false
end

return _M
