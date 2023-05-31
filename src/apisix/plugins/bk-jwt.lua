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
local errorx = require("apisix.plugins.bk-core.errorx")
local jwt_utils = require("apisix.plugins.bk-auth-verify.jwt-utils")
local pl_types = require("pl.types")
local table_concat = table.concat

local plugin_name = "bk-jwt"

local BKAPI_JWT_HEADER = "X-Bkapi-Jwt"
local BKAPI_APP_HEADER = "X-Bkapi-App"

local JWT_CACHE_TTL = 600
local JWT_CACHE_COUNT = 1000
local jwt_lrucache = core.lrucache.new(
    {
        ttl = JWT_CACHE_TTL,
        count = JWT_CACHE_COUNT,
        serial_creating = true,
        invalid_stale = true,
    }
)

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 17670,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- jwt start --
local function generate_bkapi_jwt_header(app, user, bk_gateway_name, jwt_private_key)
    local key = table_concat(
        {
            bk_gateway_name,
            app:uid(),
            user:uid(),
        }, ":"
    )
    local jwt_token = jwt_lrucache(
        key, nil, jwt_utils.generate_bk_jwt_token, bk_gateway_name, jwt_private_key, {
            app = app,
            user = user,
        }, JWT_CACHE_TTL + 900
    )

    if pl_types.is_empty(jwt_token) then
        core.log.error("failed to sign jwt")
        return nil, "sign jwt failed, please try again later, or contact API Gateway administrator to handle"
    end

    return jwt_token
end

local function generate_bkapi_app_header(app)
    local app_info, err = core.json.encode(app)
    if app_info == nil then
        core.log.error("failed to encode app info")
        return nil, "failed to encode app, " .. err
    end

    return app_info
end

function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- generate bkapi headers
    local jwt_header, err = generate_bkapi_jwt_header(
        ctx.var.bk_app, ctx.var.bk_user, ctx.var.bk_gateway_name, ctx.var.jwt_private_key
    )
    if pl_types.is_empty(jwt_header) then
        return errorx.exit_with_apigw_err(ctx, errorx.new_invalid_args():with_field("reason", err), _M)
    end
    core.request.set_header(ctx, BKAPI_JWT_HEADER, jwt_header)

    if ctx.var.bk_api_auth:contain_system_header(BKAPI_APP_HEADER) then
        local app_header, _ = generate_bkapi_app_header(ctx.var.bk_app)
        if not pl_types.is_empty(app_header) then
            core.request.set_header(ctx, BKAPI_APP_HEADER, app_header)
        end
    end
end

if _TEST then -- luacheck: ignore
    _M._generate_bkapi_jwt_header = generate_bkapi_jwt_header
end

return _M
