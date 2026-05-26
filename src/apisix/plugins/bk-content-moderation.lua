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

-- # bk-content-moderation
--
-- Request body content moderation using Aliyun TextModerationPlus API.
-- Reads and checks request body in the access phase (blocking).
-- Stores config in ctx for the companion plugin
-- bk-content-moderation-response to use for response moderation.

local ngx = ngx
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local aliyun = require(
    "apisix.plugins.bk-content-moderation.aliyun_text_moderation"
)
local uuid = require("resty.jit-uuid")
local io_open = io.open

local plugin_name = "bk-content-moderation"

local schema = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
            minLength = 1,
        },
        region_id = {
            type = "string",
            minLength = 1,
        },
        access_key_id = {
            type = "string",
            minLength = 1,
        },
        access_key_secret = {
            type = "string",
            minLength = 1,
        },

        check_request = {
            type = "boolean",
            default = true,
        },
        request_check_service = {
            type = "string",
            minLength = 1,
            default = "llm_query_moderation",
        },
        request_check_length_limit = {
            type = "number",
            default = 2000,
        },

        check_response = {
            type = "boolean",
            default = false,
        },
        response_check_service = {
            type = "string",
            minLength = 1,
            default = "llm_response_moderation",
        },
        response_check_length_limit = {
            type = "number",
            default = 5000,
        },

        risk_level_bar = {
            type = "string",
            enum = {"none", "low", "medium", "high", "max"},
            default = "high",
        },

        stream_check_mode = {
            type = "string",
            enum = {"realtime", "final_packet"},
            default = "final_packet",
        },
        stream_check_cache_size = {
            type = "integer",
            minimum = 1,
            default = 128,
        },
        stream_check_interval = {
            type = "number",
            minimum = 0.1,
            default = 3,
        },

        timeout = {
            type = "integer",
            minimum = 1,
            default = 5000,
        },
        upstream_timeout = {
            type = "integer",
            minimum = 1,
            default = 60000,
        },
        ssl_verify = {
            type = "boolean",
            default = true,
        },
        keepalive = {
            type = "boolean",
            default = true,
        },
        keepalive_pool = {
            type = "integer",
            minimum = 1,
            default = 30,
        },
        keepalive_timeout = {
            type = "integer",
            minimum = 1000,
            default = 60000,
        },
    },
    encrypt_fields = {"access_key_secret"},
    required = {
        "endpoint", "region_id", "access_key_id", "access_key_secret",
    },
}

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 17635,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function read_request_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
        return body
    end

    local file_path = ngx.req.get_body_file()
    if not file_path then
        return nil
    end

    local f, err = io_open(file_path, "r")
    if not f then
        core.log.warn("failed to open request body file: ", err)
        return nil
    end

    body = f:read("*a")
    f:close()
    return body
end


---@param conf table
---@param ctx apisix.Context
function _M.access(conf, ctx)
    ctx._content_moderation_conf = conf

    if not conf.check_request then
        return
    end

    local body = read_request_body()
    if not body or #body == 0 then
        return
    end

    local session_id = uuid.generate_v4()
    ctx._content_moderation_session_id = session_id

    local hit, advice, risk_level = aliyun.check_content(
        conf,
        session_id,
        body,
        conf.request_check_length_limit,
        conf.request_check_service
    )

    if hit then
        core.log.warn(
            "request content moderation hit, ",
            "risk_level: ", risk_level, ", ",
            "advice: ", advice or ""
        )
        local err = errorx.new_content_blocked_by_moderation()
        if advice then
            err:with_field("advice", advice)
        end
        return errorx.exit_with_apigw_err(ctx, err, _M)

    elseif hit == nil and advice then
        core.log.error(
            "request content moderation failed: ", advice
        )
    end
end


if _TEST then
    _M._read_request_body = read_request_body
end

return _M
