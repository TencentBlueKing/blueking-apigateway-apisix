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
local request = require("apisix.core.request")
local response = require("apisix.core.response")
local plugin = require("apisix.plugins.bk-request-id")

describe(
    "bk-request-id", function()

        local ctx

        before_each(
            function()
                ctx = {
                    var = {},
                }
            end
        )

        context(
            "rewrite", function()
                it(
                    "request header, X-Bkapi-Request-ID", function()
                        plugin.rewrite({}, ctx)

                        assert.is_equal(#ctx.var.bk_request_id, 36)
                        assert.is_equal(request.header(ctx, "X-Bkapi-Request-ID"), ctx.var.bk_rqeuest_id)
                    end
                )
            end
        )

        context(
            "header_filter", function()
                before_each(
                    function()
                        stub(response, "set_header")
                        stub(
                            ngx.resp, "get_headers", function()
                                return {}
                            end
                        )
                    end
                )

                after_each(
                    function()
                        response.set_header:revert()
                        ngx.resp.get_headers:revert()
                    end
                )

                it(
                    "response header", function()
                        local ctx = {
                            var = {
                                bk_request_id = "fake-request-id",
                            },
                        }
                        plugin.header_filter({}, ctx)

                        assert.stub(response.set_header).was_called_with("X-Bkapi-Request-ID", "fake-request-id")
                    end
                )
            end
        )
    end
)

describe(
    "x-request-id", function()

        context(
            "rewrite", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                        stub(request, "set_header")
                        stub(
                            ngx.req, "get_headers", function()
                                return {}
                            end
                        )
                    end
                )
                after_each(
                    function()
                        request.set_header:revert()
                        ngx.req.get_headers:revert()
                    end
                )

                it(
                    "request header, X-Request-ID, not exist will equals to 32 X-Bkapi-Request-ID", function()
                        local origin_ctx = core.table.deepcopy(ctx)
                        plugin.rewrite({}, ctx)

                        assert.is_equal(#ctx.var.bk_request_id, 36)

                        -- the ctx.var is changed before call the second core.request.set_header
                        origin_ctx.var["bk_request_id"] = ctx.var.bk_request_id

                        -- from 36 to 32
                        local uuid_val_32 = string.gsub(ctx.var.bk_request_id, "-", "")

                        assert.is_equal(#ctx.var.x_request_id, 32)
                        assert.equal(uuid_val_32, ctx.var.x_request_id)
                        assert.stub(request.set_header).was_called_with(origin_ctx, "X-Request-ID", uuid_val_32)
                    end
                )

            end
        )

        context(
            "rewrite: header exists", function()
                local ctx
                before_each(
                    function()
                        ctx = {
                            var = {},
                        }

                        stub(request, "set_header")
                        stub(
                            ngx.req, "get_headers", function()
                                return {
                                    ["X-Request-ID"] = "fake-request-id",
                                }
                            end
                        )
                    end
                )
                after_each(
                    function()
                        request.set_header:revert()
                        ngx.req.get_headers:revert()
                    end
                )

                it(
                    "request header, X-Request-ID, exist,  will use it", function()
                        local origin_ctx = core.table.deepcopy(ctx)
                        plugin.rewrite({}, ctx)

                        assert.is_equal(#ctx.var.bk_request_id, 36)
                        -- assert.is_equal(ctx.var.bk_rqeuest_id, request.header(ctx, "X-Bkapi-Request-ID"))
                        -- the ctx.var is changed before call the second core.request.set_header
                        origin_ctx.var["bk_request_id"] = ctx.var.bk_request_id

                        assert.is_equal(#ctx.var.x_request_id, 15)
                        assert.equal("fake-request-id", ctx.var.x_request_id)
                        -- assert.is_equal("fake-request-id", request.header(ctx, "X-Request-ID"))
                        assert.stub(request.set_header).was_not_called_with(origin_ctx, "X-Request-ID", "fake-request-id")
                    end
                )

            end
        )

        context(
            "header_filter", function()
                before_each(
                    function()
                        stub(response, "set_header")
                        stub(
                            ngx.resp, "get_headers", function()
                                return {}
                            end
                        )
                    end
                )

                after_each(
                    function()
                        response.set_header:revert()
                        ngx.resp.get_headers:revert()
                    end
                )

                it(
                    "response header", function()
                        local ctx = {
                            var = {
                                x_request_id = "fake-request-id",
                            },
                        }
                        plugin.header_filter({}, ctx)

                        assert.stub(response.set_header).was_called_with("X-Request-ID", "fake-request-id")
                    end
                )
            end
        )

        context(
            "header_filter: header exists", function()
                before_each(
                    function()
                        stub(response, "set_header")
                        stub(
                            ngx.resp, "get_headers", function()
                                return {
                                    ["X-Request-ID"] = "fake-request-id",
                                }
                            end
                        )
                    end
                )

                after_each(
                    function()
                        response.set_header:revert()
                        ngx.resp.get_headers:revert()
                    end
                )

                it(
                    "response header", function()
                        local ctx = {
                            var = {
                                x_request_id = "new-fake-request-id",
                            },
                        }
                        plugin.header_filter({}, ctx)

                        assert.stub(response.set_header).was_not_called_with("X-Request-ID", "new-fake-request-id")
                    end
                )
            end
        )

    end
)
