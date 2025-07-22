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

local core = require("apisix.core")

local plugin = require("apisix.plugins.bk-legacy-invalid-params")

describe(
    "bk-legacy-invalid-params",
    function()
        context(
            "rewrite",
            function()
                local ctx
                before_each(
                    function()
                        ctx = {
                            var = {}
                        }
                        stub(core.request, "set_uri_args")
                    end
                )

                after_each(
                    function()
                        -- ngx.req.clear_header:revert()
                        core.request.set_uri_args:revert()
                    end
                )

                it(
                    "no args",
                    function()
                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_not_called()
                    end
                )
                it(
                    "normal args with &",
                    function()
                        ctx.var.args = "a=1&b=2"
                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_not_called()
                    end
                )
                it(
                    "args with ;",
                    function()
                        ctx.var.args = "a=1;b=2"
                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_called_with(ctx, "a=1&b=2")
                    end
                )
                it(
                    "args with &amp;",
                    function()
                        ctx.var.args = "a=1&amp;b=2"
                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_called_with(ctx, "a=1&amp&b=2")
                    end
                )
                it(
                    "args with &amp;amp;",
                    function()
                        ctx.var.args = "a=1&amp;amp;b=2"
                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_called_with(ctx, "a=1&amp&amp&b=2")
                    end
                )

            end
        )
    end
)
