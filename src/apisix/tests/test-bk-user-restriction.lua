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

local plugin = require("apisix.plugins.bk-user-restriction")
local core = require("apisix.core")

describe("bk-user-restriction", function()
    local ctx, conf

    before_each(function()
        ctx = {
            var = {
                bk_resource_auth = true,
                user = {
                    username = "test_user",
                    verified = true,
                },
            },
        }

        conf = {
            message = "The bk-user is not allowed",
            whitelist = { "allowed_user" },
        }
    end)

    context("check schema", function()
        it("should reject invalid configuration", function()
            assert.is_false(plugin.check_schema({}))
        end)

        it("should accept valid configuration", function()
            assert.is_true(plugin.check_schema({
                whitelist = { "allowed_user" },
            }))
        end)
    end)

    context("access", function()
        it("should deny user not in whitelist", function()
            -- -- FIXME: check_schema, init the map
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.whitelist_map)

            ctx.var.user.username = "unknown_user"
            local code = plugin.access(conf, ctx)
            assert.is_equal(code, 403)
            assert.is_not_nil(ctx.var.bk_apigw_error)
        end)

        it("should allow user not in whitelist", function()
            -- -- FIXME: check_schema, init the map
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.whitelist_map)

            ctx.var.user.username = "allowed_user"
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)
        end)

        -- TODO: not hit blacklist, allowed
        -- TODO: hit blacklist, denied


    end)
end)
