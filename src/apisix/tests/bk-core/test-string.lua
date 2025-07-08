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

local bk_core = require("apisix.plugins.bk-core.init")

describe(
    "string", function()

        context(
            "trim_prefix", function()
                it(
                    "ok", function()
                        assert.is_equal(bk_core.string.trim_prefix("a", "a"), "")
                        assert.is_equal(bk_core.string.trim_prefix("ab", "a"), "b")
                        assert.is_equal(bk_core.string.trim_prefix("foo:bar", "foo:"), "bar")
                        assert.is_equal(bk_core.string.trim_prefix("a", "b"), "a")
                        assert.is_equal(bk_core.string.trim_prefix("", "bar"), "")
                    end
                )
            end
        )
    end
)
