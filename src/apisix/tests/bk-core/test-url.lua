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
    "url", function()

        context(
            "url_single_joining_slash", function()
                it(
                    "ok", function()
                        local tests = {{"https://www.google.com/", "/favicon.ico", "https://www.google.com/favicon.ico"},
                                       {"https://www.google.com", "/favicon.ico", "https://www.google.com/favicon.ico"},
                                       {"https://www.google.com", "favicon.ico", "https://www.google.com/favicon.ico"},
                                       {"https://www.google.com", "", "https://www.google.com/"},
                                       {"", "favicon.ico", "/favicon.ico"}}

                        for _, tt in pairs(tests) do
                            local result = bk_core.url.url_single_joining_slash(tt[1], tt[2])
                            assert.is_equal(result, tt[3])
                        end
                    end
                )
            end
        )

        context(
            "encode_url_values", function()
                it(
                    "ok", function()
                        local data = {{nil, ""}, {{}, ""}, {{
                            a = "1",
                        }, "a=1"}, {{
                            a = {"1"},
                        }, "a=1"}, {{
                            b = "2",
                            a = "1",
                        }, "a=1&b=2"}, {{
                            b = {"2", "3"},
                            a = "1",
                        }, "a=1&b=2&b=3"}}

                        for _, d in pairs(data) do
                            local result = bk_core.url.encode_url_values(d[1])
                            assert.is_equal(result, d[2])
                        end
                    end
                )
            end
        )

        context(
            "get_value", function()
                it(
                    "ok", function()
                        local data = {{nil, "a", nil}, {{}, "a", nil}, {{
                            a = "b",
                        }, "a", "b"}, {{
                            a = {"b", "c"},
                        }, "a", "b"}}
                        for _, d in pairs(data) do
                            local result = bk_core.url.get_value(d[1], d[2])
                            assert.is_equal(result, d[3])
                        end
                    end
                )
            end
        )
    end
)
