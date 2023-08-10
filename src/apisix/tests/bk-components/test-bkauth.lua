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
local core = require("apisix.core")
local http = require("resty.http")
local bkauth = require("apisix.plugins.bk-components.bkauth")

describe(
    "bkauth", function()

        local response, response_err

        before_each(
            function()
                response = nil
                response_err = nil

                stub(
                    http, "new", function()
                        return {
                            set_timeout = function(self, timeout)
                            end,
                            request_uri = function(self, url, params)
                                return response, response_err
                            end,
                        }
                    end
                )
            end
        )

        after_each(
            function()
                http.new:revert()
            end
        )

        context(
            "verify_app_secret", function()
                it(
                    "response nil", function()
                        response = nil
                        response_err = "error"

                        local result, err = bkauth.verify_app_secret("fake-app-code", "fake-app-secret")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "status 404", function()
                        response = {
                            status = 404,
                            body = core.json.encode(
                                {
                                    code = 404,
                                    message = "error",
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.verify_app_secret("fake-app-code", "fake-app-secret")
                        assert.is_false(result.existed)
                        assert.is_false(result.verified)
                        assert.is_nil(err)
                    end
                )

                it(
                    "response is not valid json", function()
                        response = {
                            status = 200,
                            body = "not valid json",
                        }
                        response_err = nil

                        local result, err = bkauth.verify_app_secret("fake-app-code", "fake-app-secret")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "code is not equal to 0", function()
                        response = {
                            status = 401,
                            body = core.json.encode(
                                {
                                    code = 1,
                                    message = "error",
                                    data = {
                                        is_match = false,
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.verify_app_secret("fake-app-code", "fake-app-secret")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "success, is_match = true", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    code = 0,
                                    data = {
                                        is_match = true,
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.verify_app_secret("fake-app-code", "fake-app-secret")
                        assert.is_true(result.existed)
                        assert.is_true(result.verified)
                        assert.is_nil(err)
                    end
                )

                it(
                    "success, is_match = false", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    code = 0,
                                    data = {
                                        is_match = false,
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.verify_app_secret("fake-app-code", "fake-app-secret")
                        assert.is_true(result.existed)
                        assert.is_false(result.verified)
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "list_app_secrets", function()
                it(
                    "response nil", function()
                        response = nil
                        response_err = "error"

                        local result, err = bkauth.list_app_secrets("fake-app-code")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )
                it(
                    "status 404", function()
                        response = {
                            status = 404,
                            body = core.json.encode(
                                {
                                    code = 404,
                                    message = "error",
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.list_app_secrets("fake-app-code")
                        assert.is_same(
                            result, {
                                app_secrets = {},
                            }
                        )
                        assert.is_nil(err)
                    end
                )

                it(
                    "response is not valid json", function()
                        response = {
                            status = 200,
                            body = "not valid json",
                        }
                        response_err = nil

                        local result, err = bkauth.list_app_secrets("fake-app-code")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "code is not equal to 0", function()
                        response = {
                            status = 401,
                            body = core.json.encode(
                                {
                                    code = 1,
                                    message = "error",
                                    data = {
                                        is_match = false,
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.list_app_secrets("fake-app-code")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "success", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    code = 0,
                                    data = {
                                        {
                                            bk_app_code = "app-1",
                                            bk_app_secret = "secret-1",
                                        },
                                        {
                                            bk_app_code = "app-2",
                                            bk_app_secret = "secret-2",
                                        },
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.list_app_secrets("fake-app-code")
                        assert.is_same(
                            result, {
                                app_secrets = {
                                    "secret-1",
                                    "secret-2",
                                },
                            }
                        )
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "verify_access_token", function()
                it(
                    "response is nil", function()
                        response = nil
                        response_err = "error"

                        local result, err = bkauth.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "response body is nil", function()
                        response = {
                            body = nil,
                        }
                        response_err = "error"

                        local result, err = bkauth.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "response body is not json format", function()
                        response = {
                            body = "not json",
                            status = 200,
                        }
                        response_err = nil

                        local result, err = bkauth.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "failed to request third-party api"))
                    end
                )

                it(
                    "response code is not 0", function()
                        response = {
                            body = core.json.encode(
                                {
                                    code = 1,
                                    message = "error",
                                }
                            ),
                            status = 200,
                        }
                        response_err = nil

                        local result, err = bkauth.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "bkauth error message: error"))
                    end
                )

                it(
                    "response status is not 200", function()
                        response = {
                            body = core.json.encode(
                                {
                                    code = 0,
                                    message = "error",
                                }
                            ),
                            status = 500,
                        }
                        response_err = nil

                        local result, err = bkauth.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "bkauth error message: error"))
                    end
                )

                it(
                    "success", function()
                        response = {
                            status = 200,
                            body = core.json.encode(
                                {
                                    code = 0,
                                    data = {
                                        bk_app_code = "bk-color",
                                        username = "admin",
                                        expires_in = 10,
                                    },
                                }
                            ),
                        }
                        response_err = nil

                        local result, err = bkauth.verify_access_token("fake-token")
                        assert.is_same(
                            result, {
                                bk_app_code = "bk-color",
                                username = "admin",
                                expires_in = 10,
                            }
                        )
                        assert.is_nil(err)
                    end
                )
            end
        )
    end
)
