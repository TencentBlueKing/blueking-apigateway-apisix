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
local bklogin = require("apisix.plugins.bk-components.bklogin")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

describe(
    "bklogin", function()

        local response, response_err, request_url
        local enable_multi_tenant_mode, enable_esb

        before_each(
            function()
                response = nil
                response_err = nil
                request_url = nil
                enable_multi_tenant_mode = bklogin.enable_multi_tenant_mode
                enable_esb = bklogin.enable_esb

                stub(
                    bk_components_utils, "handle_request", function(url)
                        request_url = url
                        return response, response_err
                    end
                )
            end
        )

        after_each(
            function()
                bklogin.enable_multi_tenant_mode = enable_multi_tenant_mode
                bklogin.enable_esb = enable_esb
                bk_components_utils.handle_request:revert()
            end
        )

        context(
            "get_username_by_bk_token", function()
                it(
                    "response error", function()
                        response = nil
                        response_err = "error"

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request"))
                    end
                )

                it(
                    "connection refused", function()
                        response = nil
                        response_err = "connection refused"

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_nil(result)
                        assert.equals(err, "connection refused")
                    end
                )


                it(
                    "status 400", function()
                        response = {
                            status = 400,
                            body = core.json.encode(
                                {
                                    bk_error_code = 400,
                                    bk_error_msg = "bk_token is not valid",
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_same(
                            result, {
                                error_message = "bk_token is not valid",
                            }
                        )
                        assert.is_nil(err)
                    end
                )

                it(
                    "status not 200", function()
                        response = {
                            status = 500,
                            body = core.json.encode(
                                {
                                    bk_error_code = 500,
                                    bk_error_msg = "internal server error",
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                        assert.is_true(core.string.find(err, "request_id") ~= nil)
                    end
                )

                it(
                    "legacy protocol result false", function()
                        bklogin.enable_multi_tenant_mode = false
                        bklogin.enable_esb = true
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    result = false,
                                    bk_error_code = 1302100,
                                    bk_error_msg = "bk_token is not valid",
                                    data = {},
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_same(
                            result, {
                                error_message = "bk_token is not valid",
                            }
                        )
                        assert.is_nil(err)
                    end
                )

                it(
                    "legacy protocol success without result field", function()
                        bklogin.enable_multi_tenant_mode = false
                        bklogin.enable_esb = true
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    bk_error_code = 0,
                                    bk_error_msg = "",
                                    data = {
                                        bk_username = "admin",
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_equal(result.username, "admin")
                        assert.is_nil(err)
                    end
                )

                for _, case in ipairs({
                    { name = "single tenant with ESB", esb = true, multi_tenant = false,
                      v3 = false },
                    { name = "single tenant without ESB", esb = false, multi_tenant = false,
                      v3 = true },
                    { name = "multi-tenant, ESB on", esb = true, multi_tenant = true, v3 = true },
                    { name = "multi-tenant, ESB off", esb = false, multi_tenant = true, v3 = true },
                }) do
                    it("selects the verification endpoint for " .. case.name, function()
                        bklogin.enable_multi_tenant_mode = case.multi_tenant
                        bklogin.enable_esb = case.esb
                        response = {
                            status = 200,
                            body = '{"data":{"bk_username":"admin"}}',
                        }

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_nil(err)
                        assert.equals("admin", result.username)
                        local path = case.v3 and "/login/api/v3/apigw/bk-tokens/verify/"
                            or "/login/api/v2/is_login/"
                        assert.equals(path, request_url:sub(-#path))
                    end)
                end

                it(
                    "success", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    bk_error_code = 0,
                                    bk_error_msg = "",
                                    data = {
                                        bk_username = "admin",
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bklogin.get_username_by_bk_token("fake-bk-token")
                        assert.is_equal(result.username, "admin")
                        assert.is_nil(err)
                    end
                )

            end
        )
    end
)
