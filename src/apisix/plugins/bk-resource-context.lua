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
local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")

local plugin_name = "bk-resource-context"
local schema = {
    type = "object",
    properties = {
        bk_resource_id = {
            type = "integer",
        },
        bk_resource_name = {
            type = "string",
        },
        bk_resource_auth = {
            type = "object",
            properties = {
                verified_app_required = {
                    type = "boolean",
                    default = true,
                },
                verified_user_required = {
                    type = "boolean",
                    default = true,
                },
                resource_perm_required = {
                    type = "boolean",
                    default = true,
                },
                skip_user_verification = {
                    type = "boolean",
                    default = false,
                },
            },
        },
    },
}

local _M = {
    version = 0.1,
    priority = 18820,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    conf.bk_resource_auth_obj = context_resource_bkauth.new(conf.bk_resource_auth or {})
    return true
end

function _M.rewrite(conf, ctx)
    -- 为上下文注入资源信息
    ctx.var.bk_resource_id = conf.bk_resource_id
    ctx.var.bk_resource_name = conf.bk_resource_name
    ctx.var.bk_resource_auth = conf.bk_resource_auth_obj
end

return _M
