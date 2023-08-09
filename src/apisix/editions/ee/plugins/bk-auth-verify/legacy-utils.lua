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
local bk_cache = require("apisix.plugins.bk-cache.init")
local bk_user_define = require("apisix.plugins.bk-define.user")

---@param bk_token string
---@return table user
---@return boolean has_server_error There is an internal server error.
local function verify_by_bk_token(bk_token)
    local result, err = bk_cache.get_username_by_bk_token(bk_token)
    if err ~= nil then
        return bk_user_define.new_anonymous_user(err), true
    end

    if result.error_message ~= nil then
        return bk_user_define.new_anonymous_user(result.error_message), false
    end

    return bk_user_define.new_user(
        {
            username = result.username,
            verified = true,
        }
    ), false
end

---@return table user
---@return boolean has_server_error There is an internal server error.
local function verify_by_username(username)
    return bk_user_define.new_user(
        {
            username = username,
            verified = false,
            valid_error_message = "user authentication failed, the user indicated by bk_username is not verified",
        }
    ), false
end

return {
    verify_by_bk_token = verify_by_bk_token,
    verify_by_username = verify_by_username,
}
