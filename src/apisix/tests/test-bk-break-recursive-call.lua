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
local errorx = require("apisix.plugins.bk-core.errorx")
local plugin = require("apisix.plugins.bk-break-recursive-call")

describe(
    "bk-break-recursive-call", function()
        local ctx
        local headers

        context(
            "rewrite", function()
                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                        headers = {}

                        stub(
                            core.request, "header", function(ctx, key)
                                return headers[key]
                            end
                        )
                        stub(core.request, "set_header")
                    end
                )

                after_each(
                    function()
                        core.request.header:revert()
                        core.request.set_header:revert()
                    end
                )

                it(
                    "no x-bkapi-instance-id header", function()
                        ctx.var.instance_id = "foo"
                        local code = plugin.rewrite({}, ctx)
                        assert.is_nil(code)
                        assert.stub(core.request.set_header).was_called_with(ctx, "X-Bkapi-Instance-Id", "foo")
                    end
                )

                it(
                    "no ctx.var.instance_id", function()
                        ctx.var.instance_id = nil
                        local code = plugin.rewrite({}, ctx)
                        assert.is_nil(code)
                        assert.stub(core.request.set_header).was_called_with(ctx, "X-Bkapi-Instance-Id", "bkapi")
                    end
                )

                it(
                    "detect recursive", function()
                        ctx.var.instance_id = "foo"
                        headers = {
                            ["X-Bkapi-Instance-Id"] = "green,foo,red",
                        }
                        local code = plugin.rewrite({}, ctx)
                        assert.is_equal(508, code)
                        assert.is_same(ctx.var.bk_apigw_error, errorx.new_recursive_request_detected())
                        assert.stub(core.request.set_header).was_not_called()
                    end
                )

                it(
                    "no recursive, and x-bkapi-instance-id exist", function()
                        ctx.var.instance_id = "foo"
                        headers = {
                            ["X-Bkapi-Instance-Id"] = "bar,red",
                        }
                        local code = plugin.rewrite({}, ctx)
                        assert.is_nil(code)
                        assert.stub(core.request.set_header).was_called_with(ctx, "X-Bkapi-Instance-Id", "bar,red,foo")
                    end
                )

                it(
                    "no recursive, no ctx.var.instance_id", function()
                        ctx.var.instance_id = nil
                        headers = {
                            ["X-Bkapi-Instance-Id"] = "bar,red",
                        }
                        local code = plugin.rewrite({}, ctx)
                        assert.is_nil(code)
                        assert.stub(core.request.set_header)
                            .was_called_with(ctx, "X-Bkapi-Instance-Id", "bar,red,bkapi")
                    end
                )
            end
        )
    end
)
