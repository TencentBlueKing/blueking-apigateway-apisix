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

local pl_types = require("pl.types")
local bk_cache = require("apisix.plugins.bk-cache.init")
local bk_user_define = require("apisix.plugins.bk-define.user")

local function verify_by_bk_token(bk_token)
    local username, err = bk_cache.get_username_by_bk_token(bk_token)
    if pl_types.is_empty(username) then
        return nil, err
    end

    return bk_user_define.new_user(
        {
            username = username,
            verified = true,
        }
    )
end

local function verify_by_username(username)
    return bk_user_define.new_user(
        {
            username = username,
            verified = false,
            valid_error_message = "user authentication failed, the user indicated by bk_username is not verified",
        }
    )
end

return {
    verify_by_bk_token = verify_by_bk_token,
    verify_by_username = verify_by_username,
}
