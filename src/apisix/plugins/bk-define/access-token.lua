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
local setmetatable = setmetatable

local _M = {}

function _M.new(app_code, user_id, expires_in)
    return setmetatable(
        {
            app_code = app_code or "",
            user_id = user_id or "",
            expires_in = expires_in,
        }, {
            __index = _M,
        }
    )
end

-- 获取应用 Code
function _M.get_app_code(self)
    return self.app_code
end

-- 获取用户名
function _M.get_user_id(self)
    return self.user_id
end

-- AccessToken 是否过期
function _M.has_expired(self)
    return self.expires_in <= 0
end

-- AccessToken 将会在多久过期
function _M.get_expires_in(self)
    return self.expires_in
end

-- 是否为用户类型的 AccessToken
function _M.is_user_token(self)
    return not pl_types.is_empty(self.user_id)
end

return _M
