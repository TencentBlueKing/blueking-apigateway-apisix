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

local ck = require("resty.cookie")
local bk_core = require("apisix.plugins.bk-core.init")


describe(
    "cookie",
    function()
        local cookie
        local mock_cookie

        before_each(
            function()
                mock_cookie = ck:new()
                stub(ck, "new", function() return cookie end)
            end
        )

        after_each(
            function()
                ck.new:revert()
            end
        )

        context(
            "get_value",
            function()
                it(
                    "cookie is nil",
                    function()
                        cookie = nil
                        assert.is_nil(bk_core.cookie.get_value("bk_token"))
                    end
                )

                it(
                    "cookie",
                    function()
                        cookie = mock_cookie
                        cookie._cookie = "bk_token=fake-token; foo=bar"
                        assert.is_equal(bk_core.cookie.get_value("bk_token"), "fake-token")
                        assert.is_equal(bk_core.cookie.get_value("foo"), "bar")
                        assert.is_nil(bk_core.cookie.get_value("bk_color"))
                    end
                )
            end
        )
    end
)