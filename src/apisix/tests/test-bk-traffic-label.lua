--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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
local plugin = require("apisix.plugins.bk-traffic-label")

describe(
    "bk-traffic-label", function()

        local ctx
        local conf

        before_each(
            function()
                ctx = {
                    var = {
                        uri = "/foo",
                        host = "example.com",
                        remote_addr = "127.0.0.1"
                    },
                    headers = {}
                }
                stub(core.request, "set_header")
            end
        )

        after_each(
            function()
                core.request.set_header:revert()
            end
        )

        context(
            "schema validation", function()
                it(
                    "invalid schema: empty", function()
                        conf = {}
                        local ok, err = plugin.check_schema(conf)
                        assert.is_false(ok)
                        assert.is_not_nil(err)
                    end
                )

                it(
                    "valid schema", function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header"] = "test"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        local ok, err = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "valid schema with 1 match and 3 actions with same weight", function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header-1"] = "test1"
                                            },
                                            weight = 1
                                        },
                                        {
                                            set_headers = {
                                                ["X-Test-Header-2"] = "test2"
                                            },
                                            weight = 1
                                        },
                                        {
                                            set_headers = {
                                                ["X-Test-Header-3"] = "test3"
                                            },
                                            weight = 1
                                        }
                                    }
                                }
                            }
                        }
                        local ok, err = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_nil(err)
                        assert.is_equal(conf.rules[1].actions[1].weight, 1)
                        assert.is_equal(conf.rules[1].actions[2].weight, 1)
                        assert.is_equal(conf.rules[1].actions[3].weight, 1)
                        assert.is_equal(conf.rules[1].total_weight, 3)
                    end
                )
            end
        )

        context(
            "1 rules: 1 match 1 action", function()
                before_each(
                    function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header"] = "test"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    end
                )

                it(
                    "match hit set_headers", function()
                        plugin.check_schema(conf)

                        plugin.access(conf, ctx)
                        assert.stub(core.request.set_header).was_called_with(
                            MATCH._, "X-Test-Header", "test")
                    end
                )

                it(
                    "match miss do nothing", function()
                        plugin.check_schema(conf)

                        ctx.var.uri = "/bar"
                        plugin.access(conf, ctx)
                        assert.stub(core.request.set_header).was_not_called()
                    end
                )
            end
        )

        context(
            "1 rules: 1 match 2 actions, with weight", function()
                before_each(
                    function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header-1"] = "test1"
                                            },
                                            weight = 1
                                        },
                                        {
                                            set_headers = {
                                                ["X-Test-Header-2"] = "test2"
                                            },
                                            weight = 1
                                        }
                                    }
                                }
                            }
                        }
                    end
                )

                it(
                    "multiple-actions with weight", function()
                        plugin.check_schema(conf)

                        stub(math, "random", function()
                            return 1
                        end)
                        plugin.access(conf, ctx)
                        math.random:revert()
                        assert.stub(core.request.set_header).was_called_with(
                            MATCH._, "X-Test-Header-1", "test1")
                    end
                )
            end
        )

        context(
            "1 rules: 1 match 2 actions, one with weight 0", function()
                before_each(
                    function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header-1"] = "test1"
                                            },
                                            weight = 0
                                        },
                                        {
                                            set_headers = {
                                                ["X-Test-Header-2"] = "test2"
                                            },
                                            weight = 1
                                        }
                                    }
                                }
                            }
                        }
                    end
                )

                it(
                    "only the action with non-zero weight is applied", function()
                        plugin.check_schema(conf)

                        plugin.access(conf, ctx)
                        assert.stub(core.request.set_header).was_called_with(
                            MATCH._, "X-Test-Header-2", "test2")
                    end
                )
            end
        )

        context(
            "1 rules: 1 match 2 actions, one with weight 0, another weight no set_headers", function()
                before_each(
                    function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header-1"] = "test1"
                                            },
                                            weight = 0
                                        },
                                        {
                                            weight = 1
                                        }
                                    }
                                }
                            }
                        }
                    end
                )

                it(
                    "only the action with non-zero weight is applied, but do nothing", function()
                        plugin.check_schema(conf)

                        plugin.access(conf, ctx)
                        assert.stub(core.request.set_header).was_not_called()
                    end
                )
            end
        )

        context(
            "2 rules", function()

                before_each(
                    function()
                        conf = {
                            rules = {
                                {
                                    match = {
                                        {"uri", "==", "/foo"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header-1"] = "test1"
                                            }
                                        }
                                    }
                                },
                                {
                                    match = {
                                        {"host", "==", "example.com"}
                                    },
                                    actions = {
                                        {
                                            set_headers = {
                                                ["X-Test-Header-2"] = "test2"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    end
                )

                it(
                    "multiple matches, all hit", function()
                        plugin.check_schema(conf)

                        plugin.access(conf, ctx)
                        assert.stub(core.request.set_header).was_called_with(
                            MATCH._, "X-Test-Header-1", "test1")
                        assert.stub(core.request.set_header).was_called_with(
                            MATCH._, "X-Test-Header-2", "test2")
                    end
                )

                it(
                    "multiple matches, only hit one", function()
                        plugin.check_schema(conf)

                        ctx.var.uri = "/bar"
                        plugin.access(conf, ctx)
                        assert.stub(core.request.set_header).was_called_with(
                            MATCH._, "X-Test-Header-2", "test2")
                        assert.stub(core.request.set_header).was_called(1)
                    end
                )
            end
        )

    end
)
