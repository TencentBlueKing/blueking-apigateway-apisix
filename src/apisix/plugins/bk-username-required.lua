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
-- # bk-username-required
--
-- This plugin checks that the request header contains the bk_username
-- Source:
-- 1. header： X-Bk-Username
-- 2. header: X-Bkapi-Authorization: {"bk_username"}
--
-- This plugin depends on:
--     * bk-auth-verify: Get the verified bk_user objects.
--

local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")

local plugin_name = "bk-username-required"

local BK_USERNAME_HEADER = "X-Bk-Username"

local schema = {
    type = "object",
    properties = {},
}


-- global config.yaml
local _M = {
    version = 0.1,
    priority = 18725,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- get from header first
    local username = core.request.header(ctx, BK_USERNAME_HEADER)

    -- if username is not in the header, check ctx.var.bk_username (which is set by bk-auth-verify)
    if username == nil then
        if ctx.var.bk_username == nil or ctx.var.bk_username == "" then
            return errorx.exit_with_apigw_err(
            ctx,
            errorx.new_invalid_args():with_field(
                "reason",
                "No `X-Bk-Username` header or no `bk_username` in the `X-Bkapi-Authorization` header"),
            _M)
        else
            core.request.set_header(ctx, BK_USERNAME_HEADER, ctx.var.bk_username)
        end
    -- if username is empty, return error
    elseif username == "" then
        return errorx.exit_with_apigw_err( ctx,
        errorx.new_invalid_args():with_field( "reason", "The `X-Bk-Username` header is empty"),
            _M)
    end

end


return _M
