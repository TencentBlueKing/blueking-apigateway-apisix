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
local bklogin = require("apisix.plugins.bk-components.bklogin")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

describe(
    "bklogin", function()

        local response, response_err

        before_each(
            function()
                response = nil
                response_err = nil

                stub(
                    bk_components_utils, "handle_request", function()
                        return response, response_err
                    end
                )
            end
        )

        after_each(
            function()
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
