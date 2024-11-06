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
            end
        )

        context(
            "1 ruls: 1 match 1 action", function()
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
                        assert.is_equal(ctx.headers["X-Test-Header"], "test")
                    end
                )

                it(
                    "match miss do nothing", function()
                        plugin.check_schema(conf)

                        ctx.var.uri = "/bar"
                        plugin.access(conf, ctx)
                        assert.is_nil(ctx.headers["X-Test-Header"])
                    end
                )
            end
        )

        context(
            "1 ruls: 1 match 2 actions, with weight", function()
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
                                            weight = 0.5
                                        },
                                        {
                                            set_headers = {
                                                ["X-Test-Header-2"] = "test2"
                                            },
                                            weight = 0.5
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

                        math.randomseed(os.time())
                        plugin.access(conf, ctx)
                        assert.is_true(ctx.headers["X-Test-Header-1"] == "test1" or ctx.headers["X-Test-Header-2"] == "test2")
                    end
                )
            end
        )

        context(
            "1 ruls: 1 match 2 actions, one with weight 0", function()
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
                        assert.is_nil(ctx.headers["X-Test-Header-1"])
                        assert.is_equal(ctx.headers["X-Test-Header-2"], "test2")
                    end
                )
            end
        )

        context(
            "1 ruls: 1 match 2 actions, one with weight 0, another weight no set_headers", function()
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
                        assert.is_nil(ctx.headers["X-Test-Header-1"])
                        assert.is_nil(ctx.headers["X-Test-Header-2"])
                        -- assert.is_equal(ctx.headers["X-Test-Header-2"], "test2")
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
                        assert.is_equal(ctx.headers["X-Test-Header-1"], "test1")
                        assert.is_equal(ctx.headers["X-Test-Header-2"], "test2")
                    end
                )

                it(
                    "multiple matches, only hit one", function()
                        plugin.check_schema(conf)

                        ctx.var.uri = "/bar"
                        plugin.access(conf, ctx)
                        assert.is_nil(ctx.headers["X-Test-Header-1"])
                        assert.is_equal(ctx.headers["X-Test-Header-2"], "test2")
                    end
                )
            end
        )
    end
)
