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

local core = require("apisix.core")
local stringx = require("pl.stringx")
local pl_types = require("pl.types")
local errorx = require("apisix.plugins.bk-core.errorx")
local ipairs = ipairs

local matcher_cache = core.lrucache.new(
    {
        serial_creating = true,
        invalid_stale = true,
    }
)

local groups_schema = {
    type = "array",
    items = {
        type = "object",
        properties = {
            id = {
                type = "integer",
            },
            name = {
                type = "string",
            },
            content = {
                type = "string",
            },
            comment = {
                type = "string",
            },
        },
    },
}

local schema = {
    type = "object",
    properties = {
        allow = groups_schema,
        deny = groups_schema,
    },
}

local _M = {
    version = 0.1,
    priority = 17661,
    name = "bk-ip-group-restriction",
    schema = schema,
}

---@param content string
local function create_ip_matcher(content)
    local lines = stringx.splitlines(content)
    local result = core.table.new(#lines, 0)
    local index = 1

    lines:foreach(
        function(line)
            local value = stringx.strip(line)
            -- skip the blank line and commented line
            if value == "" or stringx.startswith(value, "#") then
                return

            elseif core.ip.validate_cidr_or_ip(value) then
                result[index] = value
                index = index + 1
            end
        end
    )

    return core.ip.create_ip_matcher(result)
end

-- check if the ip is matched the pattern groups
---@param ip string
---@param groups bk_ip_group_restriction.Group[]
local function is_ip_match(ip, groups)
    -- an empty groups will match nothing
    if pl_types.is_empty(groups) then
        return false
    end

    for _, group in ipairs(groups) do
        local matcher = matcher_cache(group.content, nil, create_ip_matcher, group.content)
        if matcher and matcher:match(ip) then
            return true
        end
    end

    return false
end

-- make the request denied response
---@param ctx apisix.Context
---@param ip string
---@param reason string
local function request_denied(ctx, ip, reason)
    return errorx.exit_with_apigw_err(
        ctx, errorx.new_ip_not_allowed():with_fields(
            {
                ip = ip,
                reason = reason,
            }
        ), _M
    )
end

---@param conf bk_ip_group_restriction.Config
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

---@param conf bk_ip_group_restriction.Config
---@param ctx apisix.Context
function _M.rewrite(conf, ctx)
    local real_ip = core.request.get_remote_client_ip(ctx)
    if pl_types.is_empty(real_ip) then
        return request_denied(ctx, real_ip, "invalid ip")
    end

    if is_ip_match(real_ip, conf.deny) then
        return request_denied(ctx, real_ip, "ip is denied")
    end

    -- it should pass all requests when allow list is not set
    if conf.allow ~= nil and not is_ip_match(real_ip, conf.allow) then
        return request_denied(ctx, real_ip, "ip is not allowed")
    end
end

if _TEST then
    _M._is_ip_match = is_ip_match
    _M._request_denied = request_denied
    _M._create_ip_matcher = create_ip_matcher
end

return _M

--- typing
---@class bk_ip_group_restriction.Group IP 分组
---@field id integer
---@field name string 名称
---@field content string IP/CIDR 表达式
---@field comment string
---

---@class bk_ip_group_restriction.Config 配置
---@field allow bk_ip_group_restriction.Group[] 白名单分组
---@field deny bk_ip_group_restriction.Group[] 黑名单分组
---
