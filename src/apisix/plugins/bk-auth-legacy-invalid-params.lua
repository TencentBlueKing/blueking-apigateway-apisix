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

-- # bk-auth-legacy-invalid-params
--
-- For old gateway calling, because go 1.16 support both `&` and `;` as query string separator, but lua only support `&`
-- and in some case, the caller html escaped the `&` to `&amp;`(it's ok for go 1.16 gateway)
-- so we need to adapat the old gateway calling.
-- e.g.
-- ?app_code=appC&amp;app_secret=appC
-- ?app_code=appC&amp;amp;app_secret=appC
-- ?app_code=appC;app_secret=appC

local string_startswith = require("pl.stringx").startswith
local string_replace = require("pl.stringx").replace
local string_split = require("pl.stringx").split
local string_find = string.find
local string_gmatch = string.gmatch
local core = require("apisix.core")

local schema = {}

local _M = {
    version = 0.1,
    priority = 18731,
    name = "bk-auth-legacy-invalid-params",
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local args = core.request.get_uri_args()

    -- only query string contains `;` should be processed
    if string_find(ctx.var.args, ";") then
        -- core.log.error("before:", core.json.delay_encode(args))
        for key, val in pairs(args) do
                -- core.log.error(key, "=", val)
                if string_startswith(key, "amp;") then
                    -- we need to replace all
                    -- case: ?a=b&amp;c=d
                    -- case: ?a=b&amp;amp;c=d
                    local new_key = string_replace(key, "amp;", "")
                    args[key] = nil
                    args[new_key] = val

                    -- FIXME: will error here, should check if the key already exists, and use a table to store it
                    -- case: ?a=b&amp;a=c
                else
                    -- case: ?a=b;c=d;e=f
                    if string_find(val, ";") and string_find(val, "=") then
                        -- key=value;a=b
                        -- 1. key=value
                        args[key] = string_split(val, ";")[1]

                        -- 2. a=b
                        for k, v in string_gmatch(val, "([^;=]+)=([^;=]+)") do
                            args[k] = v
                        end

                        -- case: ?a=b;a=c
                        -- FIXME: will error here, should check if the key already exists, and use a table to store it

                    end
                end
        end
        -- core.log.error("after: ", core.json.delay_encode(args))
        core.request.set_uri_args(ctx, args)
    end

end

return _M
