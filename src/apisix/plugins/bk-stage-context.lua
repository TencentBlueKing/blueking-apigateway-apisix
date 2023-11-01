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
local bk_core = require("apisix.plugins.bk-core.init")
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")

local ngx = ngx -- luacheck: ignore
local ngx_decode_base64 = ngx.decode_base64

local plugin_name = "bk-stage-context"
local schema = {
    type = "object",
    required = {
        "bk_gateway_name",
        "bk_stage_name",
        "jwt_private_key",
        "bk_api_auth",
    },
    properties = {
        bk_gateway_name = {
            type = "string",
        },
        bk_gateway_id = {
            type = "integer",
        },
        bk_stage_name = {
            type = "string",
        },
        jwt_private_key = {
            type = "string",
        },
        bk_api_auth = {
            type = "object",
            properties = {
                api_type = {
                    type = "integer",
                },
                unfiltered_sensitive_keys = {
                    type = "array",
                    items = {
                        type = "string",
                    },
                },
                include_system_headers = {
                    type = "array",
                    items = {
                        type = "string",
                    },
                },
                allow_auth_from_params = {
                    type = "boolean",
                    default = true,
                },
                uin_conf = {
                    type = "object",
                    properties = {
                        user_type = {
                            type = "string",
                        },
                        from_uin_skey = {
                            type = "boolean",
                        },
                        skey_type = {
                            type = "integer",
                        },
                        domain_id = {
                            type = "integer",
                        },
                        search_rtx = {
                            type = "boolean",
                        },
                        search_rtx_source = {
                            type = "integer",
                        },
                        from_auth_token = {
                            type = "boolean",
                        },
                    },
                },
                rtx_conf = {
                    type = "object",
                    properties = {
                        user_type = {
                            type = "string",
                        },
                        from_operator = {
                            type = "boolean",
                        },
                        from_bk_ticket = {
                            type = "boolean",
                        },
                        from_auth_token = {
                            type = "boolean",
                        },
                    },
                },
                user_conf = {
                    type = "object",
                    properties = {
                        user_type = {
                            type = "string",
                        },
                        from_bk_token = {
                            type = "boolean",
                        },
                        from_username = {
                            type = "boolean",
                        },
                    },
                },
            },
        },
    },
}

local _M = {
    version = 0.1,
    priority = 18840,
    name = plugin_name,
    schema = schema,
}

---@param jwt_private_key string: JWT private key (encoded in Base64)
---@return string|nil, string|nil: The decoded JWT private key, or nil and error message if the decoding fails
local function decode_jwt_private_key(jwt_private_key)
    local decoded_private_key = ngx_decode_base64(jwt_private_key)
    if not decoded_private_key then
        core.log.error("failed to decode jwt_private_key with base64. jwt_private_key=", jwt_private_key)
        return nil, "failed to decode jwt_private_key with base64"
    end
    return decoded_private_key, nil
end

---@param conf table: The user-provided configuration for the plugin instance
---@return boolean, string|nil: true and nil if the configuration is valid, false and error message if not
function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    conf.decoded_jwt_private_key, err = decode_jwt_private_key(conf.jwt_private_key)
    if conf.decoded_jwt_private_key == nil then
        return false, err
    end

    conf.instance_id = bk_core.config.get_instance_id()
    conf.bk_api_auth_obj = context_api_bkauth.new(conf.bk_api_auth or {})

    return true
end

---@param conf table: The user-provided configuration for the plugin instance
---@param ctx  api.Context: The request context
function _M.rewrite(conf, ctx)
    -- Inject gateway information into the context
    ctx.var.instance_id = conf.instance_id
    ctx.var.bk_gateway_name = conf.bk_gateway_name
    ctx.var.bk_gateway_id = conf.bk_gateway_id
    ctx.var.bk_stage_name = conf.bk_stage_name
    ctx.var.jwt_private_key = conf.decoded_jwt_private_key
    ctx.var.bk_api_auth = conf.bk_api_auth_obj

    -- Inject context variables related to resource and service
    -- https://apisix.apache.org/zh/docs/apisix/apisix-variable
    ctx.var.bk_resource_name = ctx.route_name
    ctx.var.bk_service_name = ctx.service_name
end

return _M
