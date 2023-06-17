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
local ngx_req = ngx.req
local plugin = require("apisix.plugins.bk-proxy-rewrite")

describe(
    "bk-proxy-rewrite", function()

        local ctx
        local conf

        before_each(
            function()
                ctx = {
                    var = {
                        uri = "/path/value1/value2?hello=hello",
                    },
                    curr_req_matched = {
                        _method = "GET",
                        param1 = "value1",
                        param2 = "value2",
                        _path = "/path/:param1/:param2",
                    },
                    headers = {
                        todelete = "todelete",
                    },
                }
            end
        )

        context(
            "uri rewrite", function()

                before_each(
                    function()
                        conf = {
                            uri = "/newpath/${param2}/${param1}/",
                        }
                    end
                )

                it(
                    "uri param replaced", function()
                        plugin.rewrite(conf, ctx)
                        assert.is_equal(ctx.var.upstream_uri, "/newpath/value2/value1/")
                    end
                )

            end
        )

        context(
            "method rewrite", function()

                before_each(
                    function()
                        conf = {
                            method = "POST",
                        }
                        stub(ngx_req, "set_method")
                    end
                )

                after_each(
                    function()
                        ngx_req.set_method:revert()
                    end
                )

                it(
                    "method rewrited", function()
                        plugin.rewrite(conf, ctx)
                        assert.stub(ngx_req.set_method).was_called_with(ngx.HTTP_POST)
                    end
                )
            end
        )

        -- context(
        --     "scheme rewrite", function()

        --         before_each(
        --             function()
        --                 conf = {
        --                     scheme = "https",
        --                 }
        --             end
        --         )

        --         it(
        --             "method rewrited", function()
        --                 plugin.rewrite(conf, ctx)
        --                 assert.is_equal(ctx.upstream_scheme, "https")
        --             end
        --         )
        --     end
        -- )

        context(
            "header rewrite", function()

                before_each(
                    function()
                        conf = {
                            headers = {
                                toadd = "added",
                                todelete = "",
                            },
                        }
                        stub(ngx_req, "set_header")
                    end
                )

                after_each(
                    function()
                        ngx_req.set_header:revert()
                    end
                )

                it(
                    "method rewrited", function()
                        assert.is_equal(ctx.headers["todelete"], "todelete")
                        assert.is_equal(ctx.headers["toadd"], nil)
                        plugin.rewrite(conf, ctx)
                        -- NOTE: the stub is not working because the `ngx.req.set_header` was replaced by
                        -- `local req_set_header = ngx.req.set_header` in `apisix.core.request`(3.2.1)

                        -- assert.stub(ngx_req.set_header).was_called_with("toadd", "added")
                        -- assert.stub(ngx_req.set_header).was_called_with("todelete", "")
                        assert.is_equal(ctx.headers["todelete"], "")
                        assert.is_equal(ctx.headers["toadd"], "added")
                    end
                )
            end
        )
    end
)
