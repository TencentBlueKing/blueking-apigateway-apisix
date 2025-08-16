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

-- bk-request-size-limit
--
-- Limit the size of incoming requests by checking the content-length header.
-- If content-length is present and greater than the configured size, the request is rejected.
-- If no content-length header is present, the request is allowed to proceed.

local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local tostring = tostring

local plugin_name = "bk-request-size-limit"

local schema = {
    type = "object",
    title = "work with route or service object",
    properties = {
        max_body_size = {
            type = "integer",
            minimum = 1,
            description = "Maximum message body size in bytes. "
        }
    },
    required = {"max_body_size"},
}

local _M = {
    version = 0.1,
    priority = 17690,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- Get content-length header
    local content_length = tonumber(core.request.header(ctx, "Content-Length"))
    if content_length then
        if content_length > conf.max_body_size then
            return errorx.exit_with_apigw_err(ctx,
        errorx.new_request_body_size_exceed():with_field(
                "reason",
                "request body size ".. tostring(content_length) ..
                " exceeds the limit " .. tostring(conf.max_body_size)),
            _M)
        end
    end

end

return _M
