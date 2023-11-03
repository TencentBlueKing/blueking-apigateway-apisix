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
local setmetatable = setmetatable
local ipairs = ipairs

local ESB = 0

local UinConf = {}

local UinConfMt = {
    __index = UinConf,
}

function UinConf.new(uin_conf)
    uin_conf = uin_conf or {}
    return setmetatable(
        {
            user_type = uin_conf.user_type or "",
            from_uin_skey = uin_conf.from_uin_skey or false,
            skey_type = uin_conf.skey_type or 0,
            domain_id = uin_conf.domain_id or 0,
            search_rtx = uin_conf.search_rtx or false,
            search_rtx_source = uin_conf.search_rtx_source or 0,
            from_auth_token = uin_conf.from_auth_token or false,
        }, UinConfMt
    )
end

function UinConf.is_empty(self)
    return pl_types.is_empty(self.user_type)
end

function UinConf.use_p_skey(self)
    return self.skey_type == 1
end

local RtxConf = {}

local RtxConfMt = {
    __index = RtxConf,
}

function RtxConf.new(rtx_conf)
    rtx_conf = rtx_conf or {}
    return setmetatable(
        {
            user_type = rtx_conf.user_type or "",
            from_operator = rtx_conf.from_operator or false,
            from_bk_ticket = rtx_conf.from_bk_ticket or false,
            from_auth_token = rtx_conf.from_auth_token or false,
        }, RtxConfMt
    )
end

function RtxConf.is_empty(self)
    return pl_types.is_empty(self.user_type)
end

local UserConf = {}

local UserConfMt = {
    __index = UserConf,
}

function UserConf.new(user_conf)
    user_conf = user_conf or {}
    return setmetatable(
        {
            user_type = user_conf.user_type or "",
            from_bk_token = user_conf.from_bk_token or false,
            from_username = user_conf.from_username or false,
        }, UserConfMt
    )
end

function UserConf.is_empty(self)
    return pl_types.is_empty(self.user_type)
end

local ContextApiBkAuth = {}

local ContextApiBkAuthMt = {
    __index = ContextApiBkAuth,
}

function ContextApiBkAuth.new(bk_api_auth)
    -- 将 include_system_headers 转换为一个 mapping，以提高查询效率
    local include_system_headers_mapping = {}
    for _, header in ipairs(bk_api_auth.include_system_headers or {}) do
        include_system_headers_mapping[header] = true
    end

    return setmetatable(
        {
            api_type = bk_api_auth.api_type,
            unfiltered_sensitive_keys = bk_api_auth.unfiltered_sensitive_keys or {},
            include_system_headers_mapping = include_system_headers_mapping,
            allow_auth_from_params = bk_api_auth.allow_auth_from_params,
            uin_conf = UinConf.new(bk_api_auth.uin_conf),
            rtx_conf = RtxConf.new(bk_api_auth.rtx_conf),
            user_conf = UserConf.new(bk_api_auth.user_conf),
        }, ContextApiBkAuthMt
    )
end

function ContextApiBkAuth.get_api_type(self)
    return self.api_type
end

---Allow get auth_params from request parameters, such as querystring, body
---@return boolean
function ContextApiBkAuth.allow_get_auth_params_from_parameters(self)
    if self.allow_auth_from_params == nil then
        -- 默认允许从参数获取认证信息
        return true
    end
    return self.allow_auth_from_params
end

---Get the unfiltered sensitive keys.
---@return table
function ContextApiBkAuth.get_unfiltered_sensitive_keys(self)
    return self.unfiltered_sensitive_keys
end

function ContextApiBkAuth.get_uin_conf(self)
    return self.uin_conf
end

function ContextApiBkAuth.get_rtx_conf(self)
    return self.rtx_conf
end

function ContextApiBkAuth.get_user_conf(self)
    return self.user_conf
end

function ContextApiBkAuth.is_esb_api(self)
    return self.api_type == ESB
end

---Filter the sensitive params or not, do the filter if api_type is not ESB.
---@return boolean
function ContextApiBkAuth.is_filter_sensitive_params(self)
    return self.api_type ~= ESB
end

function ContextApiBkAuth.is_user_type_uin(self)
    return not self.uin_conf:is_empty()
end

function ContextApiBkAuth.from_auth_token(self)
    if self:is_user_type_uin() then
        return self.uin_conf.from_auth_token
    end

    return self.rtx_conf.from_auth_token
end

function ContextApiBkAuth.no_user_type(self)
    return self.rtx_conf:is_empty() and self.user_conf:is_empty() and self.uin_conf:is_empty()
end

-- @param header string
-- @return bool
function ContextApiBkAuth.contain_system_header(self, header)
    local existed = self.include_system_headers_mapping[header]
    if existed == nil then
        return false
    end
    return existed
end

return ContextApiBkAuth
