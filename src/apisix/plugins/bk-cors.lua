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

-- bk-cors
--
-- Handle cross-origin requests using the official cors plugin.

-- The cors preflight request should return directly without reporting an error,
-- so its priority should be higher
local cors = require("apisix.plugins.cors")
local core = require("apisix.core")
local re_compile = require("resty.core.regex").re_match_compile

local plugin_name = "bk-cors"

local bk_cors_schema = core.table.deepcopy(cors.schema)
-- NOTE: here we set the default value of expose_headers to "*"
-- because the older version of the apisix(3.2.1) is `*` and we should keep the same behavior for compatibility
bk_cors_schema.properties.expose_headers.default = "*"


-- NOTE: copied from the apisix.plugins.cors of 3.13 BEGIN --
-- only change `core.schema.check(bk_cors_schema, conf)`
local origins_pattern = [[^(\*|\*\*|null|\w+://[^,]+(,\w+://[^,]+)*)$]]

local metadata_schema = {
    type = "object",
    properties = {
        allow_origins = {
            type = "object",
            additionalProperties = {
                type = "string",
                pattern = origins_pattern
            }
        },
    },
}
local function check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    local ok, err = core.schema.check(bk_cors_schema, conf)
    if not ok then
        return false, err
    end
    if conf.allow_credential then
        if conf.allow_origins == "*" or conf.allow_methods == "*" or
            conf.allow_headers == "*" or conf.expose_headers == "*" or
            conf.timing_allow_origins == "*" then
            return false, "you can not set '*' for other option when 'allow_credential' is true"
        end
    end
    if conf.allow_origins_by_regex then
        for i, re_rule in ipairs(conf.allow_origins_by_regex) do
            local ok2, err = re_compile(re_rule, "j")
            if not ok2 then
                return false, err
            end
        end
    end

    if conf.timing_allow_origins_by_regex then
        for i, re_rule in ipairs(conf.timing_allow_origins_by_regex) do
            local ok3, err = re_compile(re_rule, "j")
            if not ok3 then
                return false, err
            end
        end
    end

    return true
end

-- NOTE: copied from the apisix.plugins.cors of 3.13 END --

local _M = {
    version = 0.1,
    priority = 17900,
    name = plugin_name,
    schema = bk_cors_schema,
    check_schema = check_schema,
    rewrite = cors.rewrite,
    header_filter = cors.header_filter,
}

return _M
