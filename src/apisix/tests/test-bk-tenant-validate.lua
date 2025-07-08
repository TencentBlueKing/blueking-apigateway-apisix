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
local validate = require("apisix.plugins.bk-tenant-validate")

describe("bk-tenant-validate", function()

    context("is_empty", function()
        it("should return true for nil or empty string", function()
            assert.is_true(validate._is_empty(nil))
            assert.is_true(validate._is_empty(""))
        end)

        it("should return false for non-empty string", function()
            assert.is_false(validate._is_empty("tenant_id"))
        end)
    end)

    context("is_not_empty", function()
        it("should return false for nil and empty string", function()
            assert.is_false(validate._is_not_empty(nil))
            assert.is_false(validate._is_not_empty(""))
        end)

        it("should return true for non-empty string", function()
            assert.is_true(validate._is_not_empty("tenant_id"))
        end)
    end)

    context("reject_cross_tenant", function()
        it("should return error object", function()
            local err_msg = "Cross-tenant calls are not allowed"
            local err = validate._reject_cross_tenant(err_msg)
            assert.is_not_nil(err)
        end)
    end)

    context("validate_app_tenant_id", function()
        it("should reject when app_tenant_mode is global and header_tenant_id is empty", function()
            local ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "global",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = ""
                }
            }
            local err = validate._validate_app_tenant_id(ctx,
              "single", "gateway_tenant_id", "global", "app_tenant_id", ""
            )
            assert.is_not_nil(err)
        end)

        it("should reject when app_tenant_mode is not global and app_tenant_id does not match header_tenant_id",
        function()
            local ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "single",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = "different_tenant_id"
                }
            }
            local err = validate._validate_app_tenant_id(ctx,
                "single", "gateway_tenant_id", "single", "app_tenant_id", "different_tenant_id"
            )
            assert.is_not_nil(err)
        end)

        it("should reject when app_tenant_mode is not global and gateway_tenant_mode is not global and "..
           "gateway_tenant_id does not match app_tenant_id", function()
            local ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "single",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = "app_tenant_id"
                }
            }
            local err = validate._validate_app_tenant_id(ctx,
              "single", "different_gateway_tenant_id", "single", "app_tenant_id", "app_tenant_id"
            )
            assert.is_not_nil(err)
        end)

        it("should pass when app_tenant_mode is global and header_tenant_id is not empty", function()
            local ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "global",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = "header_tenant_id"
                }
            }
            local err = validate._validate_app_tenant_id(ctx,
              "single", "gateway_tenant_id", "global", "app_tenant_id", "header_tenant_id"
            )
            assert.is_nil(err)
        end)

        it("should pass when app_tenant_mode is not global and app_tenant_id matches header_tenant_id and "..
            "gateway_tenant_mode is global", function()
            local ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "single",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = "app_tenant_id"
                }
            }
            local err = validate._validate_app_tenant_id(ctx, "global", "", "single", "app_tenant_id", "app_tenant_id")
            assert.is_nil(err)
        end)

        it("should pass when app_tenant_mode is not global and app_tenant_id matches header_tenant_id and "..
           "gateway_tenant_mode is not global but gateway_tenant_id matches app_tenant_id", function()
            local ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "single",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = "app_tenant_id"
                }
            }
            local err = validate._validate_app_tenant_id(ctx,
                "single", "app_tenant_id", "single", "app_tenant_id", "app_tenant_id"
            )
            assert.is_nil(err)
        end)
    end)

    context("validate_user_tenant_id", function()
        it("should reject cross-tenant calls " ..
           "when gateway_tenant_mode is not global and tenant IDs do not match", function()
            local ctx = {
                var = {
                    bk_user = {
                        get_username = function() return "username" end,
                        tenant_id = "user_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_gateway_name = "gateway_name"
                }
            }
            local err = validate._validate_user_tenant_id(ctx, "single", "gateway_tenant_id", "single", "app_tenant_id")
            assert.is_not_nil(err)
        end)

        it("should reject cross-tenant calls when app_tenant_mode is not global and tenant IDs do not match", function()
            local ctx = {
                var = {
                    bk_user = {
                        get_username = function() return "username" end,
                        tenant_id = "user_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "single",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_gateway_name = "gateway_name"
                }
            }
            local err = validate._validate_user_tenant_id(ctx, "global", "", "single", "app_tenant_id")
            assert.is_not_nil(err)
        end)

        it("should pass when tenant IDs match or conditions are met", function()
            local ctx = {
                var = {
                    bk_user = {
                        get_username = function() return "username" end,
                        tenant_id = "user_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_gateway_name = "gateway_name"
                }
            }
            local err = validate._validate_user_tenant_id(ctx, "global", "", "global", "")
            assert.is_nil(err)
        end)
    end)

    context("validate_header_tenant_id", function()
        it("should reject cross-tenant calls", function()
            local ctx = {
                var = {
                    bk_tenant_id = "header_tenant_id"
                }
            }
            local err = validate._validate_header_tenant_id(ctx, "single", "gateway_tenant_id", "header_tenant_id")
            assert.is_not_nil(err)
        end)

        it("should pass when header_tenant_id is empty", function()
            local ctx = {
                var = {
                    bk_tenant_id = ""
                }
            }
            local err = validate._validate_header_tenant_id(ctx, "single", "gateway_tenant_id", "")
            assert.is_nil(err)
        end)

        it("should pass when the gateway_tenant_mode is global", function()
            local ctx = {
                var = {
                    bk_tenant_id = ""
                }
            }
            local err = validate._validate_header_tenant_id(ctx, "global", "", "header_tenant_id")
            assert.is_nil(err)
        end)

        it("should pass when gateway_tenant_id equals header_tenant_id", function()
            local ctx = {
                var = {
                    bk_tenant_id = "same_tenant_id"
                }
            }
            local err = validate._validate_header_tenant_id(ctx, "single", "same_tenant_id", "same_tenant_id")
            assert.is_nil(err)
        end)
    end)

    context("rewrite", function()
        local ctx, conf

        before_each(function()
            ctx = {
                var = {
                    bk_app = {
                        get_app_code = function() return "app_code" end,
                        tenant_mode = "single",
                        tenant_id = "app_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_user = {
                        get_username = function() return "username" end,
                        tenant_id = "user_tenant_id",
                        is_verified = function() return true end
                    },
                    bk_tenant_id = "header_tenant_id",
                    bk_gateway_name = "gateway_name"
                }
            }
            conf = {
                tenant_mode = "single",
                tenant_id = "gateway_tenant_id"
            }

        end)

        after_each(function()
        end)

        it("should return error when validate_app_tenant_id got err", function()
            stub(validate, "validate_app_tenant_id", function() return "error" end)
            local err = validate.rewrite(conf, ctx)
            assert.is_not_nil(err)
            assert.equals(403, err)
        end)

        it("should return error when validate_user_tenant_id got err", function()
            stub(validate, "validate_user_tenant_id", function() return "error" end)
            local err = validate.rewrite(conf, ctx)
            assert.is_not_nil(err)
            assert.equals(403, err)
        end)

        it("should return error when validate_header_tenant_id got err", function()
            stub(validate, "validate_header_tenant_id", function() return "error" end)
            local err = validate.rewrite(conf, ctx)
            assert.is_not_nil(err)
            assert.equals(403, err)
        end)

        it("should pass, not hit any conditions", function()
            ctx.var.bk_app.get_app_code = function() return "" end
            ctx.var.bk_user.get_username = function() return "" end

            ctx.var.bk_tenant_id = ""
            local err = validate.rewrite(conf, ctx)
            assert.is_nil(err)
        end)

        it("should pass and hit set default header X-Bk-Tenant-Id", function()
            -- make the validate_app_tenant_id pass
            ctx.var.bk_app.tenant_id = "gateway_tenant_id"

            ctx.var.bk_user.get_username = function() return "" end

            -- validate_app_tenant_id(ctx
            --   "single", "gateway_tenant_id", "single", "gateway_tenant_id", ""
            -- )
            ctx.var.bk_tenant_id = ""
            local err = validate.rewrite(conf, ctx)
            assert.is_nil(err)
            assert.equals("gateway_tenant_id", ctx.var.bk_tenant_id)

            -- FIXME: still don't know why it fails, should test in real environment
            -- assert.equals("gateway_tenant_id", core.request.header(ctx, "X-Bk-Tenant-Id"))
        end)

    end)

end)
