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

-- # bk-legacy-invalid-params
--
-- For old gateway calling, because go 1.16 support both `&` and `;` as query string separator, but lua only support `&`
-- and in some case, the caller html escaped the `&` to `&amp;`(it's ok for go 1.16 gateway)
-- so we need to adapat the old gateway calling.
-- e.g.
-- ?app_code=appC&amp;app_secret=appC
-- ?app_code=appC&amp;amp;app_secret=appC
-- ?app_code=appC;app_secret=appC
-- ?a=1;a=2

local string_replace = require("pl.stringx").replace
local string_find = string.find
local core = require("apisix.core")

local schema = {}

local _M = {
    version = 0.1,
    priority = 18880,
    name = "bk-legacy-invalid-params",
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- FIXME: 未来新的接口使用`;`也不生效, 怎么控制范围?

    -- FIX 1
    -- in golang 1.16: strings.IndexAny(key, "&;")
    -- so here we just need to replace `;` to `&`, then reset the uri_args
    -- args will be decoded like golang version

    -- core.log.error(ctx.var.args)
    -- only query string contains `;` should be processed
    if ctx.var.args ~= nil and string_find(ctx.var.args, ";") then
        local new_args = string_replace(ctx.var.args, ";", "&")
        -- core.log.error("replace ; to &: ", new_args)
        core.request.set_uri_args(ctx, new_args)
    end
    -- local args = core.request.get_uri_args()
    -- core.log.error(core.json.delay_encode(args))
end

return _M
