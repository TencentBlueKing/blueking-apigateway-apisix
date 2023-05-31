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
local plugin = require("apisix.plugins.bk-mock")
local ngx = ngx

describe(
    "bk-mock", function()

        local conf

        before_each(
            function()
                conf = {
                    response_status = 200,
                    response_example = core.json.encode(
                        {
                            code = 0,
                        }
                    ),
                    response_headers = {},
                }
            end
        )

        context(
            "check_schema", function()
                it(
                    "ok", function()
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                    end
                )

                it(
                    "fail", function()
                        conf.response_status = 50
                        local ok = plugin.check_schema(conf)
                        assert.is_false(ok)
                    end
                )
            end
        )

        context(
            "access", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                    end
                )

                it(
                    "status 200", function()
                        local status, content = plugin.access(conf, ctx)

                        assert.is_true(ctx.var.bk_skip_error_wrapper)
                        assert.is_equal(status, 200)
                        assert.is_same(
                            content, core.json.encode(
                                {
                                    code = 0,
                                }
                            )
                        )
                    end
                )

                it(
                    "status 502", function()
                        conf.response_status = 502
                        conf.response_example = "error"

                        local status, content = plugin.access(conf, ctx)

                        assert.is_equal(status, 502)
                        assert.is_equal(content, "error")
                    end
                )
            end
        )

        context(
            "header_filter", function()
                before_each(
                    function()
                        ngx.header = {}
                        stub(core.response, "set_header")
                    end
                )

                after_each(
                    function()
                        core.response.set_header:revert()
                    end
                )

                it(
                    "set response header", function()
                        conf.response_headers = {
                            ["X-Token"] = "foo",
                        }

                        plugin.header_filter(conf)
                        assert.stub(core.response.set_header).was_called_with("X-Token", "foo")
                    end
                )

                it(
                    "not set header", function()
                        conf.response_headers = {}

                        plugin.header_filter(conf)
                        assert.stub(core.response.set_header).was_not_called()
                    end
                )

                it(
                    "header cannot be overwriten", function()
                        ngx.header["X-Token"] = "bar"
                        conf.response_headers = {
                            ["X-Token"] = "foo",
                        }

                        plugin.header_filter(conf)
                        assert.is_equal(ngx.header["X-Token"], "bar")
                    end
                )
            end
        )
    end
)
