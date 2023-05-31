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

local plugin = require("apisix.plugins.bk-verified-user-exempted-apps")

describe(
    "bk-verified-user-exempted-apps", function()

        context(
            "plugin config", function()
                it(
                    "empty config", function()
                        assert.is_true(
                            plugin.check_schema(
                                {
                                    exempted_apps = {},
                                }
                            )
                        )
                    end
                )

                it(
                    "normal config", function()
                        local conf = {
                            exempted_apps = {
                                {
                                    bk_app_code = "app1",
                                    dimension = "api",
                                    resource_ids = {},
                                },
                                {
                                    bk_app_code = "app2",
                                    dimension = "resource",
                                    resource_ids = {
                                        100,
                                        12,
                                    },
                                },
                            },
                        }
                        assert.is_true(plugin.check_schema(conf))
                        assert.is_same(
                            conf.verified_user_exempted_apps, {
                                by_gateway = {
                                    app1 = true,
                                },
                                by_resource = {
                                    app2 = {
                                        ["100"] = true,
                                        ["12"] = true,
                                    },
                                },
                            }
                        )
                    end
                )

                it(
                    "invalid config", function()
                        local conf = {
                            exempted_apps = {
                                {
                                    bk_app_code = "app2",
                                    dimension = "resource",
                                    resource_ids = {
                                        100,
                                        "12",
                                    },
                                },
                            },
                        }
                        assert.is_false(plugin.check_schema(conf))
                    end
                )

                it(
                    "invalid config", function()
                        local conf = {}
                        assert.is_false(plugin.check_schema(conf))
                    end
                )
            end
        )

        context(
            "get_verified_user_exempted_apps", function()
                it(
                    "get_verified_user_exempted_apps", function()
                        local result = plugin._get_verified_user_exempted_apps(nil)
                        assert.is_nil(result)

                        result = plugin._get_verified_user_exempted_apps({})
                        assert.is_nil(result)

                        result = plugin._get_verified_user_exempted_apps(
                            {
                                {
                                    bk_app_code = "my-test1",
                                    dimension = "api",
                                    resource_ids = {},
                                },
                                {
                                    bk_app_code = "test2",
                                    dimension = "resource",
                                    resource_ids = {
                                        10000,
                                        120000,
                                    },
                                },
                            }
                        )
                        assert.is_same(
                            result, {
                                by_gateway = {
                                    ["my-test1"] = true,
                                },
                                by_resource = {
                                    ["test2"] = {
                                        ["10000"] = true,
                                        ["120000"] = true,
                                    },
                                },
                            }
                        )
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                    end
                )

                it(
                    "empty app", function()
                        plugin.rewrite({}, ctx)
                        assert.is_nil(ctx.var.verified_user_exempted_apps)
                    end
                )

                it(
                    "normal app list", function()
                        plugin.rewrite(
                            {
                                verified_user_exempted_apps = {
                                    by_gateway = {
                                        ["app1"] = true,
                                        ["app2"] = true,
                                    },
                                    by_resource = {},

                                },
                            }, ctx
                        )
                        assert.is_same(
                            ctx.var.verified_user_exempted_apps, {
                                by_gateway = {
                                    ["app1"] = true,
                                    ["app2"] = true,
                                },
                                by_resource = {},
                            }
                        )
                    end
                )
            end
        )
    end
)
