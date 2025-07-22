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

local color_cache = core.lrucache.new({
    ttl = 10,
    count = 10,
    serial_creating = true,
    invalid_stale = true,
})


local tools = {
    get_color = function()
        return "red"
    end
}


describe(
    "lrucache",
    function()
        it(
            "should get color",
            function()
                local get_color = spy.on(tools, "get_color")

                local color, err = color_cache("color", nil, tools.get_color)
                assert.is_nil(err)
                assert.is_equal(color, "red")
                assert.spy(get_color).was_called(1)

                -- get from cache
                color_cache("color", nil, tools.get_color)
                assert.spy(get_color).was_called(1)
            end
        )
    end
)
