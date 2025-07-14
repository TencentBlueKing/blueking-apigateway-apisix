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

local plugin = require("apisix.plugins.bk-log-context")

describe(
    "bk-log-context", function()
        ---@type apisix.Context
        local ctx

        before_each(
            function()
                ngx.var.request_time = 0.1
                ctx = CTX(
                    {
                        should_log_response_body = true,
                    }
                )
                ctx.headers = {}
            end
        )

        context(
            "log_var", function()
                before_each(
                    function()
                        stub(
                            ngx.req, "start_time", function()
                                return 1662044896 -- 秒级时间戳
                            end
                        )
                        stub(
                            ngx.req, "get_method", function()
                                return "GET"
                            end
                        )
                    end
                )

                after_each(
                    function()
                        ngx.req.start_time:revert()
                        ngx.req.get_method:revert()
                    end
                )

                it(
                    "should get bk_log_request_timestamp", function()
                        assert.is_equal(ngx.req.start_time(), ctx.var.bk_log_request_timestamp)
                    end
                )

                it(
                    "should get bk_log_request_duration", function()
                        assert.is_equal(ctx.var.request_time * 1000, ctx.var.bk_log_request_duration)
                    end
                )

                it(
                    "should return 0 when upstream_response_time is not set", function()
                        ctx.var.upstream_response_time = nil
                        assert.is_equal(ctx.var.bk_log_upstream_duration, 0)
                    end
                )

                it(
                    "should return 0 when upstream_response_time is not set", function()
                        ctx.var.upstream_response_time = 1
                        assert.is_equal(ctx.var.bk_log_upstream_duration, 1000)
                    end
                )

                it(
                    "should get short request body from memory", function()
                        ctx.var.request_body = "a short content"
                        assert.is_equal(ctx.var.request_body, ctx.var.bk_log_request_body)
                    end
                )

                it(
                    "should truncate long request body from memory", function()
                        local request_body = ""
                        while string.len(request_body) < 1024 do
                            request_body = request_body .. "abcdefghijklmnopqrstuvwxyz"
                        end
                        ctx.var.request_body = request_body

                        assert.is_equal(#ctx.var.bk_log_request_body, 1024)
                    end
                )

                it(
                    "should skip log request body file", function()
                        ctx.var.request_body = nil
                        ctx.var.request_body_file = "mock-file"
                        assert.is_equal(ctx.var.bk_log_request_body, "[Body Too Large]")
                    end
                )

                it(
                    "should return empty request body", function()
                        ctx.var.request_body = nil
                        ctx.var.request_body_file = nil
                        assert.is_equal(ctx.var.bk_log_request_body, "")
                    end
                )

                it(
                    "should log bk_tenant_id when present", function()
                        ctx.headers["X-Bk-Tenant-Id"] = "tenant123"
                        assert.is_equal(ctx.var.bk_tenant_id, "tenant123")
                    end
                )

                it(
                    "should log empty bk_tenant_id when missing", function()
                        assert.is_equal(ctx.var.bk_tenant_id, "")
                    end
                )

            end
        )

        context(
            "header_filter", function()
                local conf
                before_each(
                    function()
                        conf = {}
                    end
                )

                it(
                    "should initialize _backend_part_response_body", function()
                        plugin.header_filter(conf, ctx)
                        assert.is_equal(ctx.var._backend_part_response_body, "")
                    end
                )

                it(
                    "should skip log response body when has apigw error", function()
                        ctx.var.bk_apigw_error = {
                            foo = "bar",
                        }
                        plugin.header_filter(conf, ctx)
                        assert.is_false(ctx.var.should_log_response_body)
                    end
                )

                it(
                    "should skip log response body when upstream status is nil", function()
                        plugin.header_filter(conf, ctx)
                        assert.is_true(ctx.var.should_log_response_body)
                    end
                )

                it(
                    "should log response body when upstream status is not 2xx", function()
                        ctx.var.upstream_status = "403"
                        plugin.header_filter(conf, ctx)
                        assert.is_true(ctx.var.should_log_response_body)
                    end
                )

                it(
                    "should log response body when config log_2xx_response_body is set", function()
                        ctx.var.upstream_status = "200"
                        conf.log_2xx_response_body = true
                        plugin.header_filter(conf, ctx)
                        assert.is_true(ctx.var.should_log_response_body)
                    end
                )

                it(
                    "should skip log response body when config log_2xx_response_body is not set", function()
                        ctx.var.upstream_status = "200"
                        conf.log_2xx_response_body = nil
                        plugin.header_filter(conf, ctx)
                        assert.is_false(ctx.var.should_log_response_body)
                    end
                )
            end
        )

        context(
            "body_filter", function()
                local conf

                before_each(
                    function()
                        conf = {}
                        ctx.var._backend_part_response_body = ""
                    end
                )

                it(
                    "should log nothing when response body is empty", function()
                        ngx.arg[1] = ""
                        plugin.body_filter(conf, ctx)
                        assert.is_equal("", ctx.var._backend_part_response_body)
                    end
                )

                it(
                    "should not truncate a short response body", function()
                        ngx.arg[1] = "test"
                        plugin.body_filter(conf, ctx)
                        assert.is_equal("test", ctx.var._backend_part_response_body)
                    end
                )

                it(
                    "should truncate a long response body", function()
                        -- 1026 length
                        local content = ""
                        while string.len(content) < 1024 do
                            content = content .. "abcdefghijklmnopqrstuvwxyz"
                        end
                        ngx.arg[1] = content

                        plugin.body_filter(conf, ctx)
                        assert.is_equal(1024, #ctx.var._backend_part_response_body)
                    end
                )

                it(
                    "should skip log response body", function()
                        ctx.var.should_log_response_body = false
                        plugin.body_filter(conf, ctx)
                        assert.is_equal(ctx.var._backend_part_response_body, "")
                    end
                )

                it(
                    "should log response body in the first call", function()
                        ngx.arg[1] = "A"
                        plugin.body_filter(conf, ctx)
                        ngx.arg[1] = "B"
                        plugin.body_filter(conf, ctx)

                        assert.is_equal(ctx.var._backend_part_response_body, "A")
                    end
                )
            end
        )
    end
)
