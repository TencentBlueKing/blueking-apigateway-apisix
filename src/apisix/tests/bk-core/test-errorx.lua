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
local errorx = require("apisix.plugins.bk-core.errorx")

describe(
    "create error", function()

        context(
            "apigateway error field features", function()
                local apigw_err

                before_each(
                    function()
                        apigw_err = errorx.new_invalid_args()
                    end
                )

                it(
                    "success with_field", function()
                        apigw_err:with_field("key1", "value1")
                        assert.is_equal(apigw_err.error.message, "Parameters error [key1=\"value1\"]")
                        apigw_err:with_field("key2", "value2")
                        assert.is_equal(apigw_err.error.message, "Parameters error [key1=\"value1\"] [key2=\"value2\"]")
                    end
                )

                it(
                    "success with_fields", function()
                        apigw_err:with_fields(
                            {
                                key1 = "value1",
                                key2 = "value2",
                            }
                        )
                        assert.is_not_equal(string.find(apigw_err.error.message, "key1=\"value1\""), nil)
                        assert.is_not_equal(string.find(apigw_err.error.message, "key2=\"value2\""), nil)
                    end
                )

                it(
                    "failed with_fields", function()
                        apigw_err:with_fields("error type")
                        assert.is_equal(apigw_err.error.message, "Parameters error")
                        apigw_err:with_fields(nil)
                        assert.is_equal(apigw_err.error.message, "Parameters error")
                    end
                )
            end
        )

        context(
            "apigateway error empty fields", function()
                local apigw_err

                before_each(
                    function()
                        apigw_err = errorx.new_invalid_args()
                    end
                )

                it(
                    "empty field", function()
                        apigw_err:with_fields({})
                        assert.is_equal(apigw_err.error.message, "Parameters error")
                        apigw_err:with_fields(nil)
                        assert.is_equal(apigw_err.error.message, "Parameters error")
                        apigw_err:with_fields("error type")
                        assert.is_equal(apigw_err.error.message, "Parameters error")
                    end
                )
            end
        )
    end
)

describe(
    "default error status handling", function()

        context(
            "normal error code", function()
                it(
                    "404", function()
                        local err = errorx.new_default_error_with_status(404)
                        assert(err)
                        assert.is_equal(err.status, 404)
                        assert.is_equal(err.error.code, 1640401)
                        assert.is_equal(err.error.code_name, "API_NOT_FOUND")
                        assert.is_equal(err.error.message, "API not found")
                    end
                )

                it(
                    "500", function()
                        local err = errorx.new_default_error_with_status(500)
                        assert(err)
                        assert.is_equal(err.status, 500)
                        assert.is_equal(err.error.code, 1650001)
                        assert.is_equal(err.error.code_name, "INTERNAL_SERVER_ERROR")
                        assert.is_equal(err.error.message, "Internal Server Error")
                    end
                )

                it(
                    tostring(ngx.HTTP_BAD_GATEWAY), function()
                        local err = errorx.new_default_error_with_status(ngx.HTTP_BAD_GATEWAY)
                        assert(err)
                        assert.is_equal(err.status, ngx.HTTP_BAD_GATEWAY)
                        assert.is_equal(err.error.code, (16000 + ngx.HTTP_BAD_GATEWAY) * 100)
                    end
                )
            end
        )

        context(
            "wrong error code", function()
                it(
                    "empty status", function()
                        local err = errorx.new_default_error_with_status()
                        assert.is_not_nil(err)
                        assert.is_equal(err.status, 500)
                        assert.is_equal(err.error.code, 1650070)
                        assert.is_equal(err.error.code_name, "UNKNOWN_ERROR")
                        assert.is_equal(err.error.message, "unknown error")
                    end
                )

                it(
                    "no handler", function()
                        local err = errorx.new_default_error_with_status(409)
                        assert.is_not_nil(err)
                        assert.is_equal(err.status, 409)
                        assert.is_equal(err.error.code, 1650070)
                        assert.is_equal(err.error.code_name, "UNKNOWN_ERROR")
                        assert.is_equal(err.error.message, "unknown error")
                    end
                )

                it(
                    "wrong status type", function()
                        local err = errorx.new_default_error_with_status("wrong type")
                        assert.is_not_nil(err)
                        assert.is_equal(err.status, 500)
                        assert.is_equal(err.error.code, 1650070)
                        assert.is_equal(err.error.code_name, "UNKNOWN_ERROR")
                        assert.is_equal(err.error.message, "unknown error")
                    end
                )
            end
        )
    end
)

describe(
    "exit_plugin", function()
        it(
            "should do nothing", function()
                local status = errorx.exit_plugin({}, nil, nil, nil)
                assert.is_nil(status)
            end
        )

        it(
            "should return status directly", function()
                local status = errorx.exit_plugin(
                    {
                        var = {},
                    }, 403, nil, nil
                )
                assert.is_equal(status, 403)
            end
        )

        it(
            "should reset status code to 200", function()
                local status = errorx.exit_plugin(
                    {
                        var = {
                            bk_status_rewrite_200 = true,
                        },
                    }, 200, nil, nil
                )
                assert.is_equal(status, 200)
            end
        )

        it(
            "should set skip error wrapper variable", function()
                local ctx = {
                    var = {},
                }
                errorx.exit_plugin(ctx, 403, nil, true)

                assert.is_true(ctx.var.bk_skip_error_wrapper)
            end
        )
    end
)

describe(
    "exit_with_apigw_err function", function()
        before_each(
            function()
                require("busted_resty").clear()
                stub(ngx, "exit")
            end
        )

        after_each(
            function()
                ngx.exit:revert()
            end
        )

        context(
            "normal cases", function()
                local err
                local ctx
                before_each(
                    function()
                        err = errorx.new_internal_server_error()
                        ctx = {
                            var = {},
                        }
                    end
                )

                it(
                    "normal case", function()
                        local status, msg = errorx.exit_with_apigw_err(ctx, err, nil)
                        assert.is_equal(err.status, status)
                        assert.is_equal("", msg)
                        assert.is_equal(ctx.var.bk_apigw_error, err)
                        assert.is_equal(ngx.status, 500)
                    end
                )
            end
        )

        context(
            "unexpected error", function()
                local ctx
                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                    end
                )

                it(
                    "empty error", function()
                        local status, msg = errorx.exit_with_apigw_err(ctx, nil, nil)
                        assert.is_equal(500, status)
                        assert.is_equal("", msg)
                    end
                )

            end
        )

        context(
            "unexpected ctx", function()
                it(
                    "empty ctx", function()
                        local status, msg = errorx.exit_with_apigw_err(nil, errorx.new_api_not_found(), nil)
                        assert.is_equal(500, status)
                        assert.is_equal("", msg)
                    end
                )

            end
        )

        context(
            "status_rewrite_200", function()
                local err
                local ctx
                before_each(
                    function()
                        err = errorx.new_internal_server_error()
                        ctx = {
                            var = {
                                bk_status_rewrite_200 = true,
                            },
                        }
                    end
                )

                it(
                    "normal case", function()
                        local status, msg = errorx.exit_with_apigw_err(ctx, err, nil)
                        assert.is_equal(200, status)
                        assert.is_equal("", msg)
                        assert.is_equal(ctx.var.bk_apigw_error, err)
                        assert.is_equal(200, ngx.status)
                    end
                )
            end
        )
    end
)
