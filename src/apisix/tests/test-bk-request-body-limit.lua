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

local plugin = require("apisix.plugins.bk-request-body-limit")
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")

describe(
    "bk-request-body-limit", function()
        local conf

        before_each(
            function()
                conf = {
                    max_body_size = 1024
                }
            end
        )

        context(
            "check_schema", function()
                it(
                    "valid configuration", function()
                        local ok, err = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "missing max_body_size field", function()
                        local invalid_conf = {}
                        local ok, err = plugin.check_schema(invalid_conf)
                        assert.is_false(ok)
                        assert.is_not_nil(err)
                    end
                )

                it(
                    "max_body_size field is not integer", function()
                        conf.max_body_size = "1024"
                        local ok, err = plugin.check_schema(conf)
                        assert.is_false(ok)
                        assert.is_not_nil(err)
                    end
                )

                it(
                    "max_body_size field is zero", function()
                        conf.max_body_size = 0
                        local ok, err = plugin.check_schema(conf)
                        assert.is_false(ok)
                        assert.is_not_nil(err)
                    end
                )

                it(
                    "max_body_size field is negative", function()
                        conf.max_body_size = -1
                        local ok, err = plugin.check_schema(conf)
                        assert.is_false(ok)
                        assert.is_not_nil(err)
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {}
                        }
                    end
                )

                it(
                    "no content-length header", function()
                        -- Mock core.request.header to return nil
                        local original_header = core.request.header
                        core.request.header = function(_, _) return nil end

                        local result = plugin.rewrite(conf, ctx)
                        assert.is_nil(result)

                        -- Restore original function
                        core.request.header = original_header
                    end
                )

                it(
                    "content-length within limit", function()
                        -- Mock core.request.header to return valid content-length
                        local original_header = core.request.header
                        core.request.header = function(_, _) return "512" end

                        local result = plugin.rewrite(conf, ctx)
                        assert.is_nil(result)

                        -- Restore original function
                        core.request.header = original_header
                    end
                )

                it(
                    "content-length equals limit", function()
                        -- Mock core.request.header to return content-length equal to limit
                        local original_header = core.request.header
                        core.request.header = function(_, _) return "1024" end

                        local result = plugin.rewrite(conf, ctx)
                        assert.is_nil(result)

                        -- Restore original function
                        core.request.header = original_header
                    end
                )

                it(
                    "content-length exceeds limit", function()
                        -- Mock core.request.header to return content-length exceeding limit
                        local original_header = core.request.header
                        core.request.header = function(_, _) return "2048" end

                        -- Mock errorx.exit_with_apigw_err to return expected values
                        local original_exit = errorx.exit_with_apigw_err
                        errorx.exit_with_apigw_err = function(_, err, plugin_obj)
                            -- assert.is_same(err, errorx.new_request_body_size_exceed())
                            assert.is_same(plugin_obj, plugin)
                            return 413, ""
                        end

                        local status, msg = plugin.rewrite(conf, ctx)
                        assert.is_equal(status, 413)
                        assert.is_equal(msg, "")

                        -- Restore original functions
                        core.request.header = original_header
                        errorx.exit_with_apigw_err = original_exit
                    end
                )

                it(
                    "invalid content-length header", function()
                        -- Mock core.request.header to return invalid content-length
                        local original_header = core.request.header
                        core.request.header = function(_, _) return "invalid" end

                        local result = plugin.rewrite(conf, ctx)
                        assert.is_nil(result)

                        -- Restore original function
                        core.request.header = original_header
                    end
                )
            end
        )
    end
)
