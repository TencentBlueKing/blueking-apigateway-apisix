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
local response = require("apisix.core.response")
local plugin = require("apisix.plugins.bk-error-wrapper")
local errorx = require("apisix.plugins.bk-core.errorx")
local proxy_phases = require("apisix.plugins.bk-core.proxy_phases")

describe(
    "before_proxy", function()
        local ctx

        before_each(
            function()
                ctx = CTX()
            end
        )

        it(
            "should set proxy_phase var", function()
                plugin.before_proxy({}, ctx)

                assert.is_equal(ctx.var.proxy_phase, proxy_phases.PROXYING)
            end
        )
    end
)

describe(
    "header_filter", function()
        local ctx

        before_each(
            function()
                ngx.var = {}
                stub(response, "clear_header_as_body_modified")
                stub(response, "set_header")
            end
        )

        after_each(
            function()
                response.clear_header_as_body_modified:revert()
                response.set_header:revert()
            end
        )

        context(
            "bk plugins error", function()

                before_each(
                    function()
                        ctx = CTX(
                            {
                                bk_apigw_error = errorx.new_app_verify_failed(),
                            }
                        )
                    end
                )

                it(
                    "bk plugins error", function()
                        plugin.header_filter(nil, ctx)
                        assert.is_equal(errorx.new_app_verify_failed().status, ctx.var.bk_apigw_error.status)
                        assert.is_equal(errorx.new_app_verify_failed().error.code, ctx.var.bk_apigw_error.error.code)
                        assert.stub(response.clear_header_as_body_modified).was.called()
                        assert.stub(response.set_header)
                            .was_called_with("Content-Type", "application/json; charset=utf-8")
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Code", tostring(errorx.new_app_verify_failed().error.code)
                        )
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Message", errorx.new_app_verify_failed().error.message
                        )
                        assert.is_nil(ctx.var.proxy_phase)
                    end
                )
            end
        )

        context(
            "apisix plugins error", function()

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                        ngx.var = {}
                    end
                )

                it(
                    "apisix plugins error", function()
                        ngx.status = 404
                        plugin.header_filter(nil, ctx)
                        assert.is_equal(errorx.new_api_not_found().status, ctx.var.bk_apigw_error.status)
                        assert.is_equal(errorx.new_api_not_found().error.code, ctx.var.bk_apigw_error.error.code)
                        assert.stub(response.clear_header_as_body_modified).was.called()
                        assert.stub(response.set_header)
                            .was_called_with("Content-Type", "application/json; charset=utf-8")
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Code", tostring(errorx.new_api_not_found().error.code)
                        )
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Message", errorx.new_api_not_found().error.message
                        )
                        assert.is_nil(ctx.var.proxy_phase)
                    end
                )

                it(
                    "apisix plugins error but do'not need dealing with", function()
                        ngx.status = 409
                        plugin.header_filter(nil, ctx)
                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.stub(response.clear_header_as_body_modified).was_called()
                    end
                )
            end
        )

        context(
            "upstream error", function()

                before_each(
                    function()
                        ctx = CTX(
                            {
                                upstream_status = 404,
                                upstream_connect_time = 0,
                                upstream_bytes_sent = "256",
                                upstream_bytes_received = "512",
                                upstream_header_time = 0,
                            }
                        )
                    end
                )

                it(
                    "upstream returns 4xx", function()
                        ngx.status = 404
                        plugin.header_filter(nil, ctx)
                        assert.is_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(ctx.var.proxy_phase, proxy_phases.FINISH)
                    end
                )

                it(
                    "upstream returns 5xx", function()
                        ngx.status = 502
                        plugin.header_filter(nil, ctx)
                        assert.is_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(ctx.var.proxy_phase, proxy_phases.FINISH)
                    end
                )
            end
        )

        context(
            "no error", function()

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                        ngx.var = {}
                        ngx.status = 200
                        ngx.var.upstream_status = 200
                    end
                )

                it(
                    "no error", function()
                        plugin.header_filter(nil, ctx)
                        assert.is_nil(ctx.var.bk_apigw_error)
                    end
                )
            end
        )

        context(
            "mocking server", function()

                before_each(
                    function()
                        ctx = {
                            var = {
                                bk_skip_error_wrapper = true,
                            },
                        }
                        ngx.var = {}
                        ngx.status = 404
                    end
                )

                it(
                    "mocking server", function()
                        plugin.header_filter(nil, ctx)
                        assert.is_nil(ctx.var.bk_apigw_error)
                    end
                )
            end
        )

        context(
            "debug mode", function()

                before_each(
                    function()
                        ctx = {
                            var = {
                                bk_apigw_error = errorx.new_app_verify_failed(),
                            },
                        }
                        ctx.var.bk_apigw_error.extra = {
                            plugin_name = "test-plugin",
                        }
                        ngx.var = {}
                        stub(
                            core.request, "header", function()
                                return "true"
                            end
                        )
                    end
                )

                after_each(
                    function()
                        core.request.header:revert()
                    end
                )

                it(
                    "error have debug info", function()
                        plugin.header_filter(nil, ctx)
                        assert.is_equal(errorx.new_app_verify_failed().status, ctx.var.bk_apigw_error.status)
                        assert.is_equal(errorx.new_app_verify_failed().error.code, ctx.var.bk_apigw_error.error.code)
                        assert.stub(response.clear_header_as_body_modified).was.called()
                        assert.stub(response.set_header)
                            .was_called_with("Content-Type", "application/json; charset=utf-8")
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Code", tostring(errorx.new_app_verify_failed().error.code)
                        )
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Message", errorx.new_app_verify_failed().error.message
                        )
                    end
                )

                it(
                    "error does not have debug info", function()
                        ctx.var.bk_apigw_error.extra = nil
                        plugin.header_filter(nil, ctx)
                        assert.is_equal(errorx.new_app_verify_failed().status, ctx.var.bk_apigw_error.status)
                        assert.is_equal(errorx.new_app_verify_failed().error.code, ctx.var.bk_apigw_error.error.code)
                        assert.stub(response.clear_header_as_body_modified).was.called()
                        assert.stub(response.set_header)
                            .was_called_with("Content-Type", "application/json; charset=utf-8")
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Code", tostring(errorx.new_app_verify_failed().error.code)
                        )
                        assert.stub(response.set_header).was_called_with(
                            "X-Bkapi-Error-Message", errorx.new_app_verify_failed().error.message
                        )
                    end
                )
            end
        )

        context(
            "upstream error", function()

                before_each(
                    function()
                        ctx = CTX()
                        ngx.status = 504
                    end
                )

                it(
                    "failed to connect to upstream", function()
                        ctx.var = {
                            upstream_status = 504,
                            upstream_bytes_sent = "0",
                            upstream_bytes_received = "0",
                        }
                        plugin.header_filter(nil, ctx)
                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(504, ctx.var.bk_apigw_error.status)
                        local start = string.find(
                            ctx.var.bk_apigw_error.error.message, "failed to connect to upstream", 1, true
                        )
                        assert.is_not_nil(start)
                        assert.is_equal(ctx.var.proxy_phase, proxy_phases.CONNECTING)
                    end
                )

                it(
                    "cannot send request to upstream", function()
                        ctx.var = {
                            upstream_status = 504,
                            upstream_connect_time = 0.1,
                            upstream_bytes_sent = 0,
                            upstream_bytes_received = "0",
                            upstream_header_time = "-",
                        }
                        plugin.header_filter(nil, ctx)
                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(504, ctx.var.bk_apigw_error.status)
                        local start = string.find(
                            ctx.var.bk_apigw_error.error.message, "cannot read header from upstream", 1, true
                        )
                        assert.is_not_nil(start)
                        assert.is_equal(ctx.var.proxy_phase, proxy_phases.HEADER_WAITING)
                    end
                )

                it(
                    "cannot read header from upstream", function()
                        ctx.var = {
                            upstream_status = 504,
                            upstream_connect_time = 0.1,
                            upstream_bytes_sent = "156",
                            upstream_bytes_received = "0",
                        }
                        plugin.header_filter(nil, ctx)
                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(504, ctx.var.bk_apigw_error.status)
                        local start = string.find(
                            ctx.var.bk_apigw_error.error.message, "cannot read header from upstream", 1, true
                        )
                        assert.is_not_nil(start)
                        assert.is_equal(ctx.var.proxy_phase, proxy_phases.HEADER_WAITING)
                    end
                )

                it(
                    "failed to read header from upstream", function()
                        ctx.var = {
                            upstream_status = 504,
                            upstream_connect_time = 0.1,
                            upstream_bytes_sent = "156",
                            upstream_bytes_received = "123",
                        }
                        plugin.header_filter(nil, ctx)
                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(504, ctx.var.bk_apigw_error.status)
                        local start = string.find(
                            ctx.var.bk_apigw_error.error.message, "failed to read header from upstream", 1, true
                        )
                        assert.is_not_nil(start)
                        assert.is_equal(ctx.var.proxy_phase, proxy_phases.HEAEDER_RECEIVING)
                    end
                )
            end
        )
    end
)

describe(
    "body_filter", function()
        local ctx

        before_each(
            function()
                ngx.arg[1] = ""
            end
        )

        context(
            "with apigw error (not found)", function()

                before_each(
                    function()
                        ctx = {
                            var = {
                                bk_apigw_error = errorx.new_api_not_found(),
                            },
                        }
                    end
                )

                it(
                    "will rewrite body", function()
                        ngx.arg[1] = ""
                        ngx.arg[2] = true
                        plugin.body_filter(nil, ctx)
                        local err = core.json.decode(ngx.arg[1])
                        assert.is_equal(errorx.new_api_not_found().error.code, err.code)
                        assert.is_equal(errorx.new_api_not_found().error.code_name, err.code_name)
                        assert.is_equal(errorx.new_api_not_found().error.message, err.message)
                        assert.is_true(ngx.arg[2])
                    end
                )

                it(
                    "have extra error message", function()
                        ngx.arg[1] = "{\"error_msg\": \"test error message\"}"
                        ngx.arg[2] = true
                        plugin.body_filter(nil, ctx)
                        local err = core.json.decode(ngx.arg[1])
                        assert.is_equal(errorx.new_api_not_found().error.code, err.code)
                        assert.is_equal(errorx.new_api_not_found().error.code_name, err.code_name)
                        assert.is_equal(
                            errorx.new_api_not_found():with_field("reason", "test error message").error.message,
                            err.message
                        )
                        assert.is_true(ngx.arg[2])
                    end
                )
            end
        )

        context(
            "no error", function()

                before_each(
                    function()
                        stub(core.json, "encode")
                        ctx = {
                            var = {},
                        }
                    end
                )

                after_each(
                    function()
                        core.json.encode:revert()
                    end
                )

                it(
                    "will do nothing", function()
                        plugin.body_filter(nil, ctx)
                        assert.stub(core.json.encode).called(0)
                    end
                )
            end
        )
    end
)

describe(
    "utils", function()
        context(
            "extract_error_info_from_body", function()

                it(
                    "apisix response will extract", function()
                        assert.is_equal(
                            "test error message",
                            plugin._extract_error_info_from_body("{\"error_msg\": \"test error message\"}")
                        )
                    end
                )

                it(
                    "openresty response will ignore", function()
                        assert.is_equal(
                            nil, plugin._extract_error_info_from_body(
                                [[<html>
                                    <head><title>404 Not Found</title></head>
                                    <body>
                                        <center><h1>404 Not Found</h1></center>
                                        <hr>
                                        <center>openresty</center>
                                    </body>
                                </html>]]
                            )
                        )
                    end
                )

                it(
                    "other response will directly returned", function()
                        assert.is_equal(
                            "test error message", plugin._extract_error_info_from_body("test error message")
                        )
                    end
                )
                it(
                    "empty or nil response will ignore", function()
                        assert.is_equal(nil, plugin._extract_error_info_from_body(""))
                        assert.is_equal(nil, plugin._extract_error_info_from_body(nil))
                    end
                )
            end
        )
    end
)
