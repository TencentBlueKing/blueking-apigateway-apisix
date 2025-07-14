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

local table_concat = table.concat
local setmetatable = setmetatable

local ngx = ngx -- luacheck: ignore
local ngx_md5 = ngx.md5

local BK_APP_JSON_VERSION = 1

local _M = {}

local mt = {
    __index = _M,
}

function _M.new_base_app(app)
    return setmetatable(
        {
            version = BK_APP_JSON_VERSION,
            app_code = app.app_code or "",
            verified = app.verified or false,
            valid_error_message = app.valid_error_message or "",
        }, mt
    )
end

function _M.new_app(app)
    return _M.new_base_app(app)
end

function _M.new_anonymous_app(valid_error_message)
    return _M.new_base_app(
        {
            app_code = "",
            verified = false,
            valid_error_message = valid_error_message,
        }
    )
end

function _M.get_app_code(self)
    return self.app_code
end

function _M.is_verified(self)
    return self.verified
end

function _M.uid(self)
    local id_str = table_concat(
        {
            self.version,
            self.app_code,
            tostring(self.verified),
            self.valid_error_message,
        }, ":"
    )
    return ngx_md5(id_str)
end

return _M
