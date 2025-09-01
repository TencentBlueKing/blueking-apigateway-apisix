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
local http = require("resty.http")
local ssm = require("apisix.plugins.bk-components.ssm")
local bk_components_utils = require("apisix.plugins.bk-components.utils")

describe(
    "ssm", function()

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
            "verify_access_token", function()
                it(
                    "response error", function()
                        response = nil
                        response_err = "error"

                        local result, err = ssm.verify_access_token("fake-access-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request"))
                    end
                )

                it(
                    "connection refused", function()
                        response = nil
                        response_err = "connection refused"

                        local result, err = ssm.verify_access_token("fake-access-token")
                        assert.is_nil(result)
                        assert.equals(err, "connection refused")
                    end
                )

                it(
                    "code is not 0", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    code = 1,
                                    message = "error",
                                    data = {},
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = ssm.verify_access_token("fake-access-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "access_token is invalid, ssm error message"))
                    end
                )

                it(
                    "success", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    code = 0,
                                    message = "",
                                    data = {
                                        bk_app_code = "my-app",
                                        expires_in = 1200,
                                        identity = {
                                            username = "admin",
                                            user_type = "bkuser",
                                        },
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = ssm.verify_access_token("fake-access-token")
                        assert.is_same(
                            result, {
                                bk_app_code = "my-app",
                                expires_in = 1200,
                                username = "admin",
                            }
                        )
                        assert.is_nil(err)
                    end
                )
            end
        )
    end
)
