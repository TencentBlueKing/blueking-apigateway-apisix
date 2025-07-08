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

local plugin = require("apisix.plugins.bk-ip-group-restriction")

describe(
    "bk-ip-group-restriction", function()
        context(
            "basic", function()
                it(
                    "should run after real-ip plugin", function()
                        local real_ip = require("apisix.plugins.real-ip")
                        assert.is_true(real_ip.priority > plugin.priority)
                    end
                )
            end
        )

        context(
            "check_schema", function()
                it(
                    "should ok when allow and deny are missing", function()
                        local result, _ = plugin.check_schema({})
                        assert.is_true(result)
                    end
                )

                it(
                    "should ok when allow and deny are empty", function()
                        local result, _ = plugin.check_schema(
                            {
                                allow = {},
                                deny = {},
                            }
                        )
                        assert.is_true(result)
                    end
                )

                it(
                    "should ok when allow and deny are empty", function()
                        local result, _ = plugin.check_schema(
                            {
                                allow = {{
                                    name = "allow",
                                    content = "# ip whitelist",
                                }},
                                deny = {{
                                    name = "deny",
                                    content = "# ip blacklist",
                                }},
                            }
                        )
                        assert.is_true(result)
                    end
                )
            end
        )

        context(
            "create_ip_matcher", function()
                it(
                    "should parse ipv4 address", function()
                        local matcher = plugin._create_ip_matcher("10.0.0.1")

                        assert(matcher)
                        assert.is_true(matcher:match("10.0.0.1"))
                    end
                )

                it(
                    "should parse ipv4 cidr", function()
                        local matcher = plugin._create_ip_matcher("10.0.0.0/24")

                        assert(matcher)
                        assert.is_true(matcher:match("10.0.0.1"))
                    end
                )

                it(
                    "should parse ipv6 address", function()
                        local matcher = plugin._create_ip_matcher("2017::8888")

                        assert(matcher)
                        assert.is_true(matcher:match("2017:0:0:0:0:0:0:8888"))
                    end
                )

                it(
                    "should parse ipv6 cidr", function()
                        local matcher = plugin._create_ip_matcher("2017::8888/32")

                        assert(matcher)
                        assert.is_true(matcher:match("2017:0:0:0:0:0:0:8888"))
                    end
                )

                it(
                    "should parse mixed address", function()
                        local matcher = plugin._create_ip_matcher(
                            [[
                                # ipv4
                                10.0.0.1

                                # ipv4 cidr
                                10.0.0.0/24

                                # ipv6
                                2017::8888

                                # ipv6 cidr
                                2017::8888/32
                            ]]
                        )

                        assert(matcher)

                        -- ipv4
                        assert.is_true(matcher:match("10.0.0.1"))
                        -- ipv4 cidr
                        assert.is_true(matcher:match("10.0.0.2"))
                        -- ipv6
                        assert.is_true(matcher:match("2017:0:0:0:0:0:0:8888"))
                        -- ipv6 cidr
                        assert.is_true(matcher:match("2017:0:0:0:0:0:0:9999"))
                    end
                )
            end
        )

        context(
            "is_ip_match", function()
                it(
                    "should not match when groups is nil", function()
                        assert.is_false(plugin._is_ip_match("", nil))
                    end
                )

                it(
                    "should not match when groups is empty", function()
                        assert.is_false(plugin._is_ip_match("", {}))
                    end
                )

                it(
                    "should match when pattern matches", function()
                        assert.is_true(
                            plugin._is_ip_match(
                                "127.0.0.1", {{
                                    content = "127.0.0.1",
                                }}
                            )
                        )
                    end
                )

                it(
                    "should not match when pattern does not match", function()
                        assert.is_false(
                            plugin._is_ip_match(
                                "127.0.0.2", {{
                                    content = "127.0.0.1",
                                }}
                            )
                        )
                    end
                )
            end
        )

        context(
            "request_denied", function()
                it(
                    "should return a error", function()
                        local res = plugin._request_denied(
                            {
                                var = {},
                            }, "127.0.0.1", "testing"
                        )
                        assert.is_equal(res, 403)
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local conf = {
                    allow = {{
                        name = "allow",
                        content = "127.0.0.0/24",
                    }},
                    deny = {{
                        name = "deny",
                        content = "127.0.0.1",
                    }},
                }

                it(
                    "should reject request when ip not found", function()
                        local res = plugin.rewrite(
                            conf, {
                                var = {},
                            }
                        )

                        assert.is_equal(res, 403)
                    end
                )

                it(
                    "should reject request when ip in denied groups", function()
                        local res = plugin.rewrite(
                            conf, {
                                var = {
                                    remote_addr = "127.0.0.1",
                                },
                            }
                        )

                        assert.is_equal(res, 403)
                    end
                )

                it(
                    "should reject request when ip not in allowed groups", function()
                        local res = plugin.rewrite(
                            conf, {
                                var = {
                                    remote_addr = "10.0.0.1",
                                },
                            }
                        )

                        assert.is_equal(res, 403)
                    end
                )

                it(
                    "should pass request", function()
                        local res = plugin.rewrite(
                            conf, {
                                var = {
                                    remote_addr = "127.0.0.2",
                                },
                            }
                        )

                        assert.is_nil(res)
                    end
                )

                it(
                    "should reject all requests when allow list is empty", function()
                        local res = plugin.rewrite(
                            {
                                allow = {},
                            }, {
                                var = {
                                    remote_addr = "127.0.0.1",
                                },
                            }
                        )

                        assert.is_equal(res, 403)
                    end
                )

                it(
                    "should pass all requests when allow list is not set", function()
                        local res = plugin.rewrite(
                            {}, {
                                var = {
                                    remote_addr = "127.0.0.1",
                                },
                            }
                        )

                        assert.is_nil(res)
                    end
                )
            end
        )
    end
)
