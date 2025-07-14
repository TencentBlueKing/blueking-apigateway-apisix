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
local signature_utils = require("apisix.plugins.bk-auth-verify.signature")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local ngx_time = ngx.time
local ngx_update_time = ngx.update_time
local ngx = ngx

describe(
    "signature-utils", function()

        local method
        local uri_args
        local request_uri
        local body_data

        before_each(
            function()
                method = nil
                uri_args = nil
                request_uri = nil
                body_data = nil

                stub(
                    ngx.req, "get_method", function()
                        return method
                    end
                )
                stub(
                    core.request, "get_uri_args", function()
                        return uri_args
                    end
                )
                stub(
                    core.request, "get_body", function()
                        return body_data
                    end
                )
                -- mock request path in bk_core.request.get_request_path
                stub(
                    core.request, "header", function()
                        return request_uri
                    end
                )
            end
        )

        after_each(
            function()
                ngx.req.get_method:revert()
                core.request.get_uri_args:revert()
                core.request.get_body:revert()
                core.request.header:revert()
            end
        )

        context(
            "check_nonce", function()
                it(
                    "nil", function()
                        local result, err = signature_utils._check_nonce(nil)
                        assert.is_nil(result)
                        assert.is_equal(err, "parameter bk_nonce required")
                    end
                )

                it(
                    "not number", function()
                        local result, err = signature_utils._check_nonce("abc")
                        assert.is_nil(result)
                        assert.is_equal(err, "parameter bk_nonce is invalid, it should be a positive integer")
                    end
                )

                it(
                    "negative number", function()
                        local result, err = signature_utils._check_nonce("-123")
                        assert.is_nil(result)
                        assert.is_equal(err, "parameter bk_nonce is invalid, it should be a positive integer")
                    end
                )

                it(
                    "str, ok", function()
                        local result, err = signature_utils._check_nonce("123")
                        assert.is_equal(result, 123)
                        assert.is_nil(err)
                    end
                )

                it(
                    "number, ok", function()
                        local result, err = signature_utils._check_nonce(123)
                        assert.is_equal(result, 123)
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "check_timestamp", function()
                it(
                    "nil", function()
                        local result, err = signature_utils._check_timestamp(nil)
                        assert.is_nil(result)
                        assert.is_equal(err, "parameter bk_timestamp required")
                    end
                )

                it(
                    "not number", function()
                        local result, err = signature_utils._check_timestamp("abc")
                        assert.is_nil(result)
                        assert.is_equal(err, "parameter bk_timestamp is invalid, it should be in time format")
                    end
                )

                it(
                    "expired", function()
                        ngx_update_time()
                        local now = ngx_time()

                        local result, err = signature_utils._check_timestamp(now - 600)
                        assert.is_nil(result)
                        assert.is_equal(err, "parameter bk_timestamp has expired")
                    end
                )

                it(
                    "ok", function()
                        ngx_update_time()
                        local now = ngx_time()

                        local result, err = signature_utils._check_timestamp(now + 10)
                        assert.is_equal(result, now + 10)
                        assert.is_nil(err)
                    end
                )

                it(
                    "str, ok", function()
                        ngx_update_time()
                        local now = ngx_time()

                        local result, err = signature_utils._check_timestamp(tostring(now + 10))
                        assert.is_equal(result, now + 10)
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "pop_signature", function()
                it(
                    "only has bk_signature", function()
                        -- bk_signature has multiple values
                        local query = {
                            bk_signature = {
                                "test",
                                "test2",
                            },
                        }
                        local result = signature_utils._pop_signature(query)
                        assert.is_same(query, {})
                        assert.is_equal(result, "test")

                        -- bk_signature has single value
                        query = {
                            bk_signature = "test",
                        }
                        result = signature_utils._pop_signature(query)
                        assert.is_same(query, {})
                        assert.is_equal(result, "test")

                        -- bk_signature is empty
                        query = {
                            bk_signature = "",
                        }
                        result = signature_utils._pop_signature(query)
                        assert.is_same(query, {})
                        assert.is_equal(result, nil)
                    end
                )

                it(
                    "only has signature", function()
                        -- only has signature
                        local query = {
                            signature = "test",
                        }
                        local result = signature_utils._pop_signature(query)
                        assert.is_same(query, {})
                        assert.is_equal(result, "test")

                        -- signature is empty
                        query = {
                            signature = "",
                        }
                        result = signature_utils._pop_signature(query)
                        assert.is_same(query, {})
                        assert.is_equal(result, "")
                    end
                )

                it(
                    "has bk_signature, signature", function()
                        local query = {
                            bk_signature = "test1",
                            signature = "test2",
                        }
                        local result = signature_utils._pop_signature(query)
                        assert.is_same(
                            query, {
                                signature = "test2",
                            }
                        )
                        assert.is_equal(result, "test1")

                        -- bk_signature is empty
                        query = {
                            bk_signature = "",
                            signature = "test2",
                        }
                        result = signature_utils._pop_signature(query)
                        assert.is_same(query, {})
                        assert.is_equal(result, "test2")
                    end
                )
            end
        )

        context(
            "validate_params", function()
                it(
                    "validate", function()
                        local now = ngx_time()

                        local err = signature_utils._validate_params("abc", now)
                        assert.is_not_nil(err)

                        err = signature_utils._validate_params(12345, now - 600)
                        assert.is_not_nil(err)

                        err = signature_utils._validate_params(12345, now)
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "signature v1 verify", function()
                it(
                    "cannot modify uri args", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = "esb_test",
                            type = "1",
                            bk_app_code = "esb_test",
                            operator = "admin",
                            bk_signature = "t7mHsuxyrz5e/2dSMqQrrXkHB60=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }
                        local copied_uri_args = core.table.deepcopy(uri_args)

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_same(core.request.get_uri_args(), copied_uri_args)
                    end
                )

                it(
                    "ok, GET, bk_signature", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = "esb_test",
                            type = "1",
                            bk_app_code = "esb_test",
                            operator = "admin",
                            bk_signature = "t7mHsuxyrz5e/2dSMqQrrXkHB60=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_true(result)
                        assert.is_nil(err)
                    end
                )

                it(
                    "one app-secret error, another is ok, bk_signature; values in table", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = {
                                "esb_test",
                            },
                            type = {
                                "1",
                            },
                            bk_app_code = {
                                "esb_test",
                            },
                            operator = {
                                "admin",
                            },
                            bk_signature = {
                                "t7mHsuxyrz5e/2dSMqQrrXkHB60=",
                            },
                            bk_timestamp = {
                                "1872768279",
                            },
                            bk_nonce = {
                                "12345",
                            },
                        }

                        local app_secrets = {
                            "test",
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "GET, signature", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = "esb_test",
                            type = "1",
                            bk_app_code = "esb_test",
                            operator = "admin",
                            signature = "t7mHsuxyrz5e/2dSMqQrrXkHB60=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "bk_signature, signature exists at same time", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = "esb_test",
                            type = "1",
                            bk_app_code = "esb_test",
                            operator = "admin",
                            bk_signature = "4t7Xq6J+2YsQhMv4O4G2vBqKIXY=",
                            signature = "test",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "POST, bk_signature", function()
                        method = "POST"
                        request_uri = "/echo/"
                        body_data = [[{"bk_app_code": "esb_test", "operator": "admin", "app_code": "esb_test", "type": 1}]]
                        uri_args = {
                            bk_signature = "FqN/cFQoNrxhQ74Css+O9jVpEFA=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "POST, signature", function()
                        method = "POST"
                        request_uri = "/echo/"
                        body_data = [[{"bk_app_code": "esb_test", "operator": "admin", "app_code": "esb_test", "type": 1}]]
                        uri_args = {
                            signature = "FqN/cFQoNrxhQ74Css+O9jVpEFA=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "bk_nonce illegal", function()
                        method = "POST"
                        request_uri = "/echo/"
                        body_data = [[{"bk_app_code": "esb_test", "operator": "admin", "app_code": "esb_test", "type": 1}]]
                        uri_args = {
                            signature = "FqN/cFQoNrxhQ74Css+O9jVpEFA=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "abc",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_equal(err, "parameter bk_nonce is invalid, it should be a positive integer")
                        assert.is_false(result)
                    end
                )

                it(
                    "bk_timestamp expired", function()
                        method = "POST"
                        request_uri = "/echo/"
                        body_data = [[{"bk_app_code": "esb_test", "operator": "admin", "app_code": "esb_test", "type": 1}]]
                        uri_args = {
                            signature = "FqN/cFQoNrxhQ74Css+O9jVpEFA=",
                            bk_timestamp = "1558502149",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_equal(err, "parameter bk_timestamp has expired")
                        assert.is_false(result)

                    end
                )

                it(
                    "signature error", function()
                        method = "POST"
                        request_uri = "/echo/"
                        body_data = [[{"bk_app_code": "esb_test", "operator": "admin", "app_code": "esb_test", "type": 1}]]
                        uri_args = {
                            signature = "J/vr4p2QOuT7I1Jk+MwdR7nxJaX=",
                            -- signature = "FqN/cFQoNrxhQ74Css+O9jVpEFA=",
                            bk_timestamp = "1872768279",
                            bk_nonce = "12345",
                        }

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v1:verify(app_secrets, nil)
                        assert.is_nil(err)
                        assert.is_false(result)
                    end
                )
            end
        )

        context(
            "signature v2 verify", function()
                it(
                    "GET, ok", function()
                        method = "GET"
                        request_uri = "/echo/"
                        body_data = ""
                        uri_args = {
                            app_code = "esb_test",
                            type = "1",
                        }

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "a4d3234d923a9a9e6115ea644199e93ab2d60155",
                                bk_timestamp = 1872768279,
                                bk_nonce = 12345,
                            }
                        )

                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "one app-secret error, another is ok, bk_signature; values in table", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = {
                                "esb_test",
                            },
                            type = {
                                "1",
                            },
                        }

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "a4d3234d923a9a9e6115ea644199e93ab2d60155",
                                bk_timestamp = 1872768279,
                                bk_nonce = 12345,
                            }
                        )
                        local app_secrets = {
                            "test",
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "GET, signature", function()
                        method = "GET"
                        request_uri = "/echo/"
                        uri_args = {
                            app_code = "esb_test",
                            type = "1",
                        }

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                signature = "a4d3234d923a9a9e6115ea644199e93ab2d60155",
                                bk_timestamp = 1872768279,
                                bk_nonce = 12345,
                            }
                        )
                        local app_secrets = {
                            "valid-app-secret",
                        }
                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "POST", function()
                        method = "POST"
                        request_uri = "/echo/"
                        uri_args = {}
                        body_data = [[{"app_code": "esb_test", "type": 1}]]

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "99e65e6c440ba29e48e51fecbb916e6aba627065",
                                bk_timestamp = 1872768279,
                                bk_nonce = 12345,
                            }
                        )
                        local app_secrets = {
                            "valid-app-secret",
                        }

                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "POST, second request", function()
                        method = "POST"
                        request_uri = "/echo/"
                        uri_args = {}
                        body_data = [[{"app_code": "esb_test", "type": 1}]]

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "99e65e6c440ba29e48e51fecbb916e6aba627065",
                                bk_timestamp = 1872768279,
                                bk_nonce = 12345,
                            }
                        )
                        local app_secrets = {
                            "valid-app-secret",
                        }

                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_nil(err)
                        assert.is_true(result)
                    end
                )

                it(
                    "bk_nonce illegal", function()
                        method = "POST"
                        request_uri = "/echo/"
                        uri_args = {}
                        body_data = [[{"app_code": "esb_test", "type": 1}]]

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "99e65e6c440ba29e48e51fecbb916e6aba627065",
                                bk_timestamp = 1872768279,
                                bk_nonce = "abc",
                            }
                        )
                        local app_secrets = {
                            "valid-app-secret",
                        }

                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_equal(err, "parameter bk_nonce is invalid, it should be a positive integer")
                        assert.is_false(result)
                    end
                )

                it(
                    "bk_timestamp expired", function()
                        method = "POST"
                        request_uri = "/echo/"
                        uri_args = {}
                        body_data = [[{"app_code": "esb_test", "type": 1}]]

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "99e65e6c440ba29e48e51fecbb916e6aba627065",
                                bk_timestamp = 1558502149,
                                bk_nonce = 12345,
                            }
                        )
                        local app_secrets = {
                            "valid-app-secret",
                        }

                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_equal(err, "parameter bk_timestamp has expired")
                        assert.is_false(result)
                    end
                )

                it(
                    "signature error", function()
                        method = "POST"
                        request_uri = "/echo/"
                        uri_args = {}
                        body_data = [[{"app_code": "esb_test", "type": 1}]]

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "esb_test",
                                operator = "admin",
                                bk_signature = "c402abd099760d35395f83a2fd55738b21229ze2",
                                bk_timestamp = 1872768279,
                                bk_nonce = 12345,
                            }
                        )
                        local app_secrets = {
                            "valid-app-secret",
                        }

                        local result, err = signature_utils.signature_verifier_v2:verify(app_secrets, auth_params)
                        assert.is_nil(err)
                        assert.is_false(result)
                    end
                )
            end
        )
    end
)
