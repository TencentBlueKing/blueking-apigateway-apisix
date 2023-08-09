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
local app_account_utils = require("apisix.plugins.bk-auth-verify.app-account-utils")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_cache = require("apisix.plugins.bk-cache.init")
local setmetatable = setmetatable

local _M = {}

local mt = {
    __index = _M,
}

---@param auth_params table Auth params from request
function _M.new(auth_params)
    local app_code = auth_params:get_first_no_nil_string_from_two_keys("bk_app_code", "app_code")
    local app_secret = auth_params:get_first_no_nil_string_from_two_keys("bk_app_secret", "app_secret")

    return setmetatable(
        {
            app_code = app_code,
            app_secret = app_secret,
            auth_params = auth_params,
        }, mt
    )
end

---@return table app
---@return boolean has_server_error There is an internal server error.
function _M.verify_app(self)
    if pl_types.is_empty(self.app_code) then
        return bk_app_define.new_anonymous_app("app code cannot be empty"), false
    end

    if not pl_types.is_empty(self.app_secret) then
        return self:verify_by_app_secret()
    end

    local signature_verifier = app_account_utils.get_signature_verifier(self.auth_params)
    if signature_verifier ~= nil then
        return self:verify_by_signature(signature_verifier)
    end

    -- 未提供有效的应用认证信息
    return bk_app_define.new_app(
        {
            app_code = self.app_code,
            exists = false,
            verified = false,
            valid_secret = false,
            valid_signature = false,
            valid_error_message = "please provide bk_app_secret or bk_signature to verify app",
        }
    ), false
end

---@param signature_verifier table
---@return table app
---@return boolean has_server_error There is an internal server error.
function _M.verify_by_signature(self, signature_verifier)
    local result, err = bk_cache.list_app_secrets(self.app_code)
    if err ~= nil then
        local app = bk_app_define.new_anonymous_app(err)
        app.app_code = self.app_code
        return app, true
    end

    if result.error_message ~= nil then
        local app = bk_app_define.new_anonymous_app(result.error_message)
        app.app_code = self.app_code
        return app, false
    end

    local verified
    local exists = not pl_types.is_empty(result.app_secrets)
    if exists then
        verified, err = signature_verifier:verify(result.app_secrets, self.auth_params)
    end

    local error_message = ""
    if err ~= nil then
        error_message = err
    elseif not exists then
        error_message = "app not found"
    elseif not verified then
        error_message = "signature [bk_signature] verification failed, please provide valid bk_signature"
    end

    return bk_app_define.new_app(
        {
            app_code = self.app_code,
            exists = exists,
            verified = verified,
            valid_secret = false,
            valid_signature = verified,
            valid_error_message = error_message,
        }
    ), false
end

---@return table app
---@return boolean has_server_error There is an internal server error.
function _M.verify_by_app_secret(self)
    local result, err = bk_cache.verify_app_secret(self.app_code, self.app_secret)
    if err ~= nil then
        local app = bk_app_define.new_anonymous_app(err)
        app.app_code = self.app_code
        return app, true
    end

    if result.error_message ~= nil then
        local app = bk_app_define.new_anonymous_app(result.error_message)
        app.app_code = self.app_code
        return app, false
    end

    local error_message = ""
    if not result.existed then
        error_message = "app not found"
    elseif not result.verified then
        error_message = "bk_app_code or bk_app_secret is incorrect"
    end

    return bk_app_define.new_app(
        {
            app_code = self.app_code,
            exists = result.existed,
            verified = result.verified,
            valid_secret = result.verified,
            valid_signature = false,
            valid_error_message = error_message,
        }
    ), false
end

return _M
