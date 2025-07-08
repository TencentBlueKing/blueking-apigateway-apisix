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
local app_account_utils = require("apisix.plugins.bk-auth-verify.app-account-utils")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")

describe(
    "app account utils", function()

        local uri_args

        before_each(
            function()
                stub(
                    core.request, "get_uri_args", function()
                        return uri_args
                    end
                )
            end
        )

        after_each(
            function()
                core.request.get_uri_args:revert()
            end
        )

        context(
            "get_signature_verifier", function()
                it(
                    "signature verifier v1", function()
                        uri_args = {
                            bk_signature = "fake-signature",
                        }

                        local verifier = app_account_utils.get_signature_verifier()
                        assert.is_equal(verifier.version, "v1")
                    end
                )

                it(
                    "nil", function()
                        uri_args = {}

                        local verifier = app_account_utils.get_signature_verifier()
                        assert.is_nil(verifier)
                    end
                )
            end
        )
    end
)
