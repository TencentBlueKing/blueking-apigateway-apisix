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

local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")


local schema = {
        type = "object",
        properties = {
            whitelist = {
                type = "array",
                items = { type = "string" },
                minItems = 1,
            },
            blacklist = {
                type = "array",
                items = { type = "string" },
                minItems = 1,
            },
            message = {
                type = "string",
                default = "The bk-user is not allowed",
                minLength = 1,
                maxLength = 1024,
            },
        },
        oneOf = {
            { required = { "whitelist" } },
            { required = { "blacklist" } },
        },
}

local plugin_name = "bk-user-restriction"

local _M = {
    version = 0.1,
    priority = 17679,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    if not core.schema.check(_M.schema, conf) then
        return false
    end

    if conf.whitelist then
        conf.whitelist_map = {}
        for _, user in ipairs(conf.whitelist) do
            conf.whitelist_map[user] = true
        end
    end

    if conf.blacklist then
        conf.blacklist_map = {}
        for _, user in ipairs(conf.blacklist) do
            conf.blacklist_map[user] = true
        end
    end

    return true
end

---@param conf any
---@param ctx apisix.Context
function _M.access(conf, ctx)
    -- Return directly if "bk-resource-auth" is not loaded by checking "bk_resource_auth"
    if ctx.var.bk_resource_auth == nil then
        return
    end

    -- not verified user required, return directly(do nothing)
    if not ctx.var.bk_resource_auth:get_verified_user_required() then
        return
    end

    -- if user is nil, return directly(do nothing)
    if ctx.var.user == nil then
        return
    end

    -- if user is not verified, return directly(do nothing)
    if ctx.var.user.verified == false then
        return
    end

    local bk_username = ctx.var.user.username

    if conf.whitelist_map and not conf.whitelist_map[bk_username] then
        return errorx.exit_with_apigw_err(
            ctx,
            errorx.new_bk_user_not_allowed():with_fields({ message = conf.message, bk_username = bk_username }),
            _M
        )
    end

    if conf.blacklist_map and conf.blacklist_map[bk_username] then
        return errorx.exit_with_apigw_err(
            ctx,
            errorx.new_bk_user_not_allowed():with_fields({ message = conf.message, bk_username = bk_username }),
            _M
        )
    end
end

return _M