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
                    "request header", function()
                        plugin.rewrite({}, ctx)

                        assert.is_equal(#ctx.var.bk_request_id, 36)
                        assert.is_equal(request.header(ctx, "X-Bkapi-Request-Id"), ctx.var.bk_rqeuest_id)
                    end
                )
            end
        )

        context(
            "header_filter", function()
                before_each(
                    function()
                        stub(response, "set_header")
                    end
                )

                after_each(
                    function()
                        response.set_header:revert()
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

                        assert.stub(response.set_header).was_called_with("X-Bkapi-Request-Id", "fake-request-id")
                    end
                )
            end
        )
    end
)
