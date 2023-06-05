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

local response = require("apisix.core.response")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")
local plugin = require("apisix.plugins.bk-auth-validate")

describe(
    "bk-auth-validate", function()
        context(
            "test is_app_exempted_from_verified_user functions", function()
                local cases = {
                    -- whitelist config is absent
                    {
                        app_code = "test",
                        resource_id = 100,
                        verified_user_exempted_apps = nil,
                        expected = false,
                    },
                    -- app code is empty
                    {
                        app_code = "",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test1 = true,
                                test2 = true,
                            },
                            by_resource = {},
                        },
                        expected = false,
                    },
                    -- app matches whitelist, by_gateway
                    {
                        app_code = "test1",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test1 = true,
                                test2 = true,
                            },
                            by_resource = {},
                        },
                        expected = true,
                    },
                    -- app matches whitelist, by_resource
                    {
                        app_code = "test1",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test2 = true,
                            },
                            by_resource = {
                                test1 = {
                                    ["100"] = true,
                                },
                            },
                        },
                        expected = true,
                    },
                    -- app not in whitelist
                    {
                        app_code = "test",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test1 = true,
                                test2 = true,
                            },
                            by_resource = {},
                        },
                        expected = false,
                    },
                }

                for _, test in pairs(cases) do
                    local result = plugin._is_app_exempted_from_verified_user(
                        test.app_code, test.resource_id, test.verified_user_exempted_apps
                    )
                    assert.is_equal(result, test.expected)
                end
            end
        )

        context(
            "validate app", function()
                context(
                    "ok", function()
                        it(
                            "app verification not required", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = false,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )

                                local err = plugin._validate_app(bk_resource_auth, app)
                                assert.is_nil(err)
                            end
                        )

                        it(
                            "verification required with verified app", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = true,
                                        valid_error_message = "",
                                    }
                                )

                                local err = plugin._validate_app(bk_resource_auth, app)
                                assert.is_nil(err)
                            end
                        )
                    end
                )

                context(
                    "validate fail", function()
                        it(
                            "verification required with unverified app", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )

                                local err = plugin._validate_app(bk_resource_auth, app)
                                assert.is_equal(err, "error")
                            end
                        )
                    end
                )
            end
        )

        context(
            "validate user", function()
                context(
                    "ok", function()
                        it(
                            "user verification is skipped", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = true,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local err = plugin._validate_user(100, bk_resource_auth, user, app, nil)
                                assert.is_nil(err)
                            end
                        )

                        it(
                            "user verification not required", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = false,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )

                                local err = plugin._validate_user(100, bk_resource_auth, user, app, nil)
                                assert.is_nil(err)
                            end
                        )

                        it(
                            "user verification required with unverified user, while app is exempted", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local err = plugin._validate_user(
                                    100, bk_resource_auth, user, app, {
                                        by_gateway = {
                                            foo = true,
                                        },
                                        bk_resource = {},
                                    }
                                )
                                assert.is_nil(err)
                            end
                        )

                        it(
                            "user verification required with verified user", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = true,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                    }
                                )

                                local err = plugin._validate_user(100, bk_resource_auth, user, app, nil)
                                assert.is_nil(err)
                            end
                        )
                    end
                )

                context(
                    "validate fail", function()
                        it(
                            "user verification required with unverified user", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                    }
                                )

                                local err = plugin._validate_user(100, bk_resource_auth, user, app, nil)
                                assert.is_equal(err, "error")
                            end
                        )
                    end
                )
            end
        )

        context(
            "rewrite", function()
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
                    "validate app ok", function()
                        local ctx = {
                            var = {
                                bk_user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                ),
                                bk_app = bk_app_define.new_app(
                                    {
                                        verified = true,
                                    }
                                ),
                                bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                        verified_user_required = false,
                                    }
                                ),
                            },
                        }

                        local status = plugin.rewrite({}, ctx)
                        assert.is_nil(status)
                        assert.is_nil(ctx.var.bk_apigw_error)
                    end
                )

                it(
                    "validate app fail", function()
                        local ctx = {
                            var = {
                                bk_user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                ),
                                bk_app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                ),
                                bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                        verified_user_required = false,
                                    }
                                ),
                            },
                        }

                        local status = plugin.rewrite({}, ctx)
                        assert.is_equal(status, 400)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1640001)
                    end
                )

                it(
                    "validate user ok", function()
                        local ctx = {
                            var = {
                                bk_user = bk_user_define.new_user(
                                    {
                                        verified = true,
                                    }
                                ),
                                bk_app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                ),
                                bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = false,
                                        verified_user_required = true,
                                    }
                                ),
                            },
                        }

                        local status = plugin.rewrite({}, ctx)
                        assert.is_nil(status)
                        assert.is_nil(ctx.var.bk_apigw_error)
                    end
                )

                it(
                    "validate user fail", function()
                        local ctx = {
                            var = {
                                bk_user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                ),
                                bk_app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                ),
                                bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = false,
                                        verified_user_required = true,
                                    }
                                ),
                            },
                        }

                        local status = plugin.rewrite({}, ctx)
                        assert.is_equal(status, 400)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1640001)
                    end
                )

                it(
                    "dependencies not provided", function()
                        -- Given an empty context object, the function should still works
                        assert.is_nil(plugin.rewrite({}, { var = {} }))
                    end
                )
            end
        )
    end
)
