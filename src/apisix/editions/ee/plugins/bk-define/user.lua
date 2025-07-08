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

local ngx = ngx -- luacheck: ignore
local ngx_md5 = ngx.md5
local table_concat = table.concat
local setmetatable = setmetatable

local BK_USER_JSON_VERSION = 1

local _M = {}

local mt = {
    __index = _M,
}

function _M.new_base_user(user)
    return setmetatable(
        {
            version = BK_USER_JSON_VERSION,
            username = user.username or "",
            verified = user.verified or false,
            valid_error_message = user.valid_error_message or "",
        }, mt
    )
end

function _M.new_user(user)
    return _M.new_base_user(user)
end

function _M.new_anonymous_user(valid_error_message)
    return _M.new_base_user(
        {
            username = "",
            verified = false,
            valid_error_message = valid_error_message,
        }
    )
end

function _M.get_username(self)
    return self.username
end

function _M.is_verified(self)
    return self.verified
end

function _M.uid(self)
    local id_str = table_concat(
        {
            self.version,
            self.username,
            tostring(self.verified),
            self.valid_error_message,
        }, ":"
    )
    return ngx_md5(id_str)
end

return _M
