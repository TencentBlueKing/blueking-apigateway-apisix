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
local bk_cache = require("apisix.plugins.bk-cache.init")

local string_format = string.format

---Verify access_token. If there is a server error, it is indicated as an internal server error,
---which is distinguished from verification failures.
---@param access_token string|nil
---@return table|nil token
---@return string|nil err
---@return boolean|nil is_server_error When err is nil, is_server_error should be nil
local function verify_access_token(access_token)
    if pl_types.is_empty(access_token) then
        return nil, "access_token cannot be empty", false
    end

    local result, err = bk_cache.get_access_token(access_token)
    if err ~= nil then
        return nil, err, true
    end

    if result.error_message ~= nil then
        return nil, result.error_message, false
    end

    local token = result.token
    if token:has_expired() then
        if token:is_user_token() then
            err =
                string_format("the access_token of the user(%s) has expired, please re-authorize", token:get_user_id())
            return nil, err, false
        end

        return nil, "access_token has expired", false
    end

    return token, nil, nil
end

return {
    verify_access_token = verify_access_token,
}
