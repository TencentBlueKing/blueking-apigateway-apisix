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

local bk_username_required = require("apisix.plugins.bk-username-required")
local errorx = require("apisix.plugins.bk-core.errorx")
local core = require("apisix.core")

describe(
    "bk-username-required", function()

        context(
            "plugin metadata", function()
                it(
                    "should have correct metadata", function()
                        assert.is_equal(bk_username_required.name, "bk-username-required")
                        assert.is_equal(bk_username_required.version, 0.1)
                        assert.is_equal(bk_username_required.priority, 18725)
                        assert.is_not_nil(bk_username_required.schema)
                    end
                )
            end
        )

        context(
            "check_schema", function()
                it(
                    "should accept empty configuration", function()
                        local conf = {}
                        local ok, err = bk_username_required.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

            end
        )

        context(
            "rewrite function", function()
                local ctx
                local conf

                before_each(
                    function()
                        ctx = {
                            var = {}
                        }
                        conf = {}
                    end
                )

                it(
                    "should pass when X-Bk-Username header is present and not empty", function()
                        -- Mock core.request.header to return a valid username
                        stub(core.request, "header", function(_, header_name)
                            if header_name == "X-Bk-Username" then
                                return "test-user"
                            end
                            return nil
                        end)

                        local result = bk_username_required.rewrite(conf, ctx)
                        assert.is_nil(result)

                        core.request.header:revert()
                    end
                )

                it(
                    "should pass when X-Bk-Username header is not present but ctx.var.bk_username is set", function()
                        -- Mock core.request.header to return nil (no header)
                        stub(core.request, "header", function(_, header_name)
                            if header_name == "X-Bk-Username" then
                                return nil
                            end
                            return nil
                        end)

                        -- Set ctx.var.bk_username
                        ctx.var.bk_username = "test-user-from-ctx"

                        local result = bk_username_required.rewrite(conf, ctx)
                        assert.is_nil(result)

                        core.request.header:revert()
                    end
                )

                it(
                    "should return error when X-Bk-Username header is empty", function()
                        -- Mock core.request.header to return empty string
                        stub(core.request, "header", function(_, header_name)
                            if header_name == "X-Bk-Username" then
                                return ""
                            end
                            return nil
                        end)

                        local status = bk_username_required.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)

                        core.request.header:revert()
                    end
                )

                it(
                    "should return error when neither X-Bk-Username header nor ctx.var.bk_username is present", function()
                        -- Mock core.request.header to return nil (no header)
                        stub(core.request, "header", function(_, header_name)
                            if header_name == "X-Bk-Username" then
                                return nil
                            end
                            return nil
                        end)

                        -- Ensure ctx.var.bk_username is nil
                        ctx.var.bk_username = nil

                        local status = bk_username_required.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)

                        core.request.header:revert()
                    end
                )

                it(
                    "should return error when ctx.var.bk_username is empty string", function()
                        -- Mock core.request.header to return nil (no header)
                        stub(core.request, "header", function(_, header_name)
                            if header_name == "X-Bk-Username" then
                                return nil
                            end
                            return nil
                        end)

                        -- Set ctx.var.bk_username to empty string
                        ctx.var.bk_username = ""

                        local status = bk_username_required.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)

                        core.request.header:revert()
                    end
                )


            end
        )

    end
)
