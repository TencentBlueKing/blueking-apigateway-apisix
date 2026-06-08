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
local plugin = require("apisix.plugins.bk-query-string-rewrite")

describe(
    "bk-query-string-rewrite", function()

        local ctx
        local uri_args

        before_each(
            function()
                uri_args = {}
                ctx = {
                    var = {
                        uri = "/path/value1/value2",
                    },
                    conf_id = "conf_id",
                    conf_type = "conf_type",
                }
                stub(
                    core.request, "get_uri_args", function()
                        return uri_args
                    end
                )
                stub(core.request, "set_uri_args")
            end
        )

        after_each(
            function()
                core.request.get_uri_args:revert()
                core.request.set_uri_args:revert()
            end
        )

        context(
            "add", function()

                it(
                    "adds param when not present", function()
                        uri_args = {}
                        local conf = {
                            add = {
                                version = "v2",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                version = "v2",
                            }
                        )
                    end
                )

                it(
                    "skips param when already present", function()
                        uri_args = {
                            version = "v1",
                        }
                        local conf = {
                            add = {
                                version = "v2",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_not_called()
                    end
                )

                it(
                    "adds multiple params, skips existing ones", function()
                        uri_args = {
                            existing = "old",
                        }
                        local conf = {
                            add = {
                                existing = "new",
                                added = "value",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                existing = "old",
                                added = "value",
                            }
                        )
                    end
                )
            end
        )

        context(
            "set", function()

                it(
                    "sets new param", function()
                        uri_args = {}
                        local conf = {
                            set = {
                                version = "v2",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                version = "v2",
                            }
                        )
                    end
                )

                it(
                    "replaces existing param", function()
                        uri_args = {
                            version = "v1",
                            other = "keep",
                        }
                        local conf = {
                            set = {
                                version = "v2",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                version = "v2",
                                other = "keep",
                            }
                        )
                    end
                )
            end
        )

        context(
            "remove", function()

                it(
                    "removes existing param", function()
                        uri_args = {
                            toremove = "value",
                            keep = "value",
                        }
                        local conf = {
                            remove = {"toremove"},
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                keep = "value",
                            }
                        )
                    end
                )

                it(
                    "no-op when param does not exist", function()
                        uri_args = {
                            keep = "value",
                        }
                        local conf = {
                            remove = {"nonexistent"},
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_not_called()
                    end
                )
            end
        )

        context(
            "combined operations", function()

                it(
                    "add, set, and remove together", function()
                        uri_args = {
                            existing = "old",
                            toremove = "bye",
                        }
                        local conf = {
                            add = {
                                existing = "should-skip",
                                added = "new",
                            },
                            set = {
                                forced = "value",
                            },
                            remove = {"toremove"},
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                existing = "old",
                                added = "new",
                                forced = "value",
                            }
                        )
                    end
                )
            end
        )

        context(
            "no changes", function()

                it(
                    "does not call set_uri_args when nothing changes", function()
                        uri_args = {
                            existing = "value",
                        }
                        local conf = {
                            add = {
                                existing = "skip",
                            },
                            remove = {"nonexistent"},
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_not_called()
                    end
                )
            end
        )

        context(
            "variable resolution", function()

                it(
                    "resolves variables in set values", function()
                        uri_args = {}
                        ctx.var.uri = "/test/path"
                        local conf = {
                            set = {
                                current_uri = "$uri",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                current_uri = "/test/path",
                            }
                        )
                    end
                )

                it(
                    "resolves variables in add values", function()
                        uri_args = {}
                        ctx.var.uri = "/test/path"
                        local conf = {
                            add = {
                                current_uri = "$uri",
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                current_uri = "/test/path",
                            }
                        )
                    end
                )
            end
        )

        context(
            "number values", function()

                it(
                    "converts number values to string", function()
                        uri_args = {}
                        local conf = {
                            set = {
                                count = 42,
                            },
                        }
                        plugin.rewrite(conf, ctx)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                count = "42",
                            }
                        )
                    end
                )
            end
        )
    end
)
