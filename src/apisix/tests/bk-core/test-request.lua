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
local bk_core = require("apisix.plugins.bk-core.init")
local ngx = ngx

describe(
    "request", function()

        local post_args
        local body_data
        local headers

        before_each(
            function()
                post_args = nil
                body_data = nil
                headers = {}
                ngx.var.request_uri = ""

                stub(
                    core.request, "get_body", function()
                        return body_data
                    end
                )
                stub(
                    core.request, "get_post_args", function()
                        return post_args
                    end
                )
                stub(
                    core.request, "header", function(ctx, key)
                        return headers[key]
                    end
                )
            end
        )

        after_each(
            function()
                core.request.get_body:revert()
                core.request.get_post_args:revert()
                core.request.header:revert()
            end
        )

        context(
            "get_content_type", function()
                it(
                    "Content-Type empty", function()
                        headers = {}

                        local content_type = bk_core.request._get_content_type()
                        assert.is_equal(content_type, "application/octet-stream")
                    end
                )

                it(
                    "Content-Type exist", function()
                        headers = {
                            ["Content-Type"] = "application/json",
                        }

                        local content_type = bk_core.request._get_content_type()
                        assert.is_equal(content_type, "application/json")
                    end
                )
            end
        )

        context(
            "is_urlencoded_form", function()
                it(
                    "is not", function()
                        headers = {}

                        local result = bk_core.request._is_urlencoded_form()
                        assert.is_false(result)
                    end
                )

                it(
                    "is", function()
                        headers = {
                            ["Content-Type"] = "application/x-www-form-urlencoded; charset=utf8",
                        }

                        local result = bk_core.request._is_urlencoded_form()
                        assert.is_true(result)
                    end
                )

                it(
                    "header is table", function()
                        headers = {
                            ["Content-Type"] = {
                                "foo",
                                "application/x-www-form-urlencoded; charset=utf8",
                            },
                        }

                        local result = bk_core.request._is_urlencoded_form()
                        assert.is_true(result)

                        headers = {
                            ["Content-Type"] = {
                                "foo",
                                "bar",
                            },
                        }

                        local result = bk_core.request._is_urlencoded_form()
                        assert.is_false(result)
                    end
                )
            end
        )

        context(
            "is_multipart_form", function()
                it(
                    "is not", function()
                        headers = {}

                        local result = bk_core.request._is_multipart_form()
                        assert.is_false(result)
                    end
                )

                it(
                    "is", function()
                        headers = {
                            ["Content-Type"] = "multipart/form-data; charset=utf8",
                        }

                        local result = bk_core.request._is_multipart_form()
                        assert.is_true(result)
                    end
                )

                it(
                    "header is table", function()
                        headers = {
                            ["Content-Type"] = {
                                "foo",
                                "multipart/form-data; charset=utf8",
                            },
                        }

                        local result = bk_core.request._is_multipart_form()
                        assert.is_true(result)

                        headers = {
                            ["Content-Type"] = {
                                "foo",
                                "bar",
                            },
                        }

                        local result = bk_core.request._is_multipart_form()
                        assert.is_false(result)
                    end
                )
            end
        )

        context(
            "parse_json_body", function()
                it(
                    "body is empty", function()
                        body_data = nil

                        local json_body, err = bk_core.request.parse_json_body()
                        assert.is_nil(json_body)
                        assert.is_equal(err, "not a json body")
                    end
                )

                it(
                    "body is not json", function()
                        body_data = "not json"

                        local json_body, err = bk_core.request.parse_json_body()
                        assert.is_nil(json_body)
                        assert.is_equal(err, "not a json body")
                    end
                )

                it(
                    "ok", function()
                        body_data = core.json.encode(
                            {
                                a = "b",
                            }
                        )

                        local json_body, err = bk_core.request.parse_json_body()
                        assert.is_same(
                            json_body, {
                                a = "b",
                            }
                        )
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "get_json_body", function()
                local req_json_body

                before_each(
                    function()
                        stub(
                            bk_core.request, "parse_json_body", function()
                                return req_json_body
                            end
                        )
                    end
                )

                after_each(
                    function()
                        bk_core.request.parse_json_body:revert()
                    end
                )

                it(
                    "not nil", function()
                        req_json_body = {}
                        local ctx = {}

                        local json_body = bk_core.request.get_json_body(ctx)
                        assert.is_same(json_body, {})
                        assert.stub(bk_core.request.parse_json_body).was_called(1)

                        json_body = bk_core.request.get_json_body(ctx)
                        assert.is_same(json_body, {})
                        assert.stub(bk_core.request.parse_json_body).was_called(1)
                    end
                )

                it(
                    "nil", function()
                        req_json_body = nil
                        local ctx = {}

                        local json_body = bk_core.request.get_json_body(ctx)
                        assert.is_same(json_body, nil)
                        assert.stub(bk_core.request.parse_json_body).was_called(1)

                        json_body = bk_core.request.get_json_body(ctx)
                        assert.is_same(json_body, nil)
                        assert.stub(bk_core.request.parse_json_body).was_called(1)
                    end
                )
            end
        )

        context(
            "parse_form", function()
                local method

                before_each(
                    function()
                        method = "GET"
                        stub(
                            ngx.req, "get_method", function()
                                return method
                            end
                        )
                    end
                )

                after_each(
                    function()
                        ngx.req.get_method:revert()
                    end
                )

                it(
                    "should not check form", function()
                        headers = {
                            ["Content-Type"] = "application/x-www-form-urlencoded",
                        }
                        post_args = {
                            a = "b",
                        }

                        method = "GET"
                        local result = bk_core.request.parse_form()
                        assert.is_nil(result)

                        method = "POST"
                        result = bk_core.request.parse_form()
                        assert.is_same(
                            result, {
                                a = "b",
                            }
                        )

                        method = "PUT"
                        result = bk_core.request.parse_form()
                        assert.is_same(
                            result, {
                                a = "b",
                            }
                        )

                        method = "PATCH"
                        result = bk_core.request.parse_form()
                        assert.is_same(
                            result, {
                                a = "b",
                            }
                        )

                        method = "DELETE"
                        result = bk_core.request.parse_form()
                        assert.is_nil(result)
                    end
                )

                it(
                    "not urlencoded", function()
                        method = "POST"
                        local data = bk_core.request.parse_form()
                        assert.is_nil(data)
                    end
                )

                it(
                    "urlencoded", function()
                        method = "POST"
                        headers = {
                            ["Content-Type"] = "application/x-www-form-urlencoded",
                        }
                        post_args = {
                            a = "b",
                        }

                        local data = bk_core.request.parse_form()
                        assert.is_same(
                            data, {
                                a = "b",
                            }
                        )
                    end
                )
            end
        )

        context(
            "get_form_data", function()
                local req_form_data

                before_each(
                    function()
                        stub(
                            bk_core.request, "parse_form", function()
                                return req_form_data
                            end
                        )
                    end
                )

                after_each(
                    function()
                        bk_core.request.parse_form:revert()
                    end
                )

                it(
                    "not nil", function()
                        req_form_data = {}
                        local ctx = {}

                        local form_data = bk_core.request.get_form_data(ctx)
                        assert.is_same(form_data, {})
                        assert.stub(bk_core.request.parse_form).was_called(1)

                        form_data = bk_core.request.get_form_data(ctx)
                        assert.is_same(form_data, {})
                        assert.stub(bk_core.request.parse_form).was_called(1)
                    end
                )

                it(
                    "nil", function()
                        req_form_data = nil
                        local ctx = {}

                        local form_data = bk_core.request.get_form_data(ctx)
                        assert.is_same(form_data, nil)
                        assert.stub(bk_core.request.parse_form).was_called(1)

                        form_data = bk_core.request.get_form_data(ctx)
                        assert.is_same(form_data, nil)
                        assert.stub(bk_core.request.parse_form).was_called(1)
                    end
                )
            end
        )

        context(
            "parse_multipart_form", function()
                it(
                    "not multipart", function()
                        headers = {}

                        local data = bk_core.request.parse_multipart_form()
                        assert.is_nil(data)
                    end
                )

                it(
                    "body empty", function()
                        headers = {
                            ["Content-Type"] = "multipart/form-data",
                        }

                        body_data = nil
                        local data = bk_core.request.parse_multipart_form()
                        assert.is_nil(data)
                        assert.stub(core.request.get_body).was_called(1)

                        body_data = ""
                        data = bk_core.request.parse_multipart_form()
                        assert.is_nil(data)
                        assert.stub(core.request.get_body).was_called(2)
                    end
                )

                it(
                    "ok", function()
                        headers = {
                            ["Content-Type"] = "Content-Type:multipart/form-data; boundary=329a699f107b4e978e346bf347036736",
                        }
                        body_data = "--329a699f107b4e978e346bf347036736\n" ..
                                        "Content-Disposition: form-data; name=\"a\"\n" .. "\n" .. "b\n" ..
                                        "--329a699f107b4e978e346bf347036736--"

                        local data = bk_core.request.parse_multipart_form()
                        assert.is_same(
                            data, {
                                a = "b",
                            }
                        )
                    end
                )
            end
        )

        context(
            "get_request_path", function()
                it(
                    "has X-Request-Uri header", function()
                        headers = {
                            ["X-Request-Uri"] = "/echo/?a=b",
                        }
                        local path = bk_core.request.get_request_path()
                        assert.is_equal(path, "/echo/")

                        headers = {
                            ["X-Request-Uri"] = "/echo/",
                        }
                        path = bk_core.request.get_request_path()
                        assert.is_equal(path, "/echo/")
                    end
                )

                it(
                    "ngx uri", function()
                        CTX(
                            {
                                uri = "/echo/",
                            }
                        )

                        local path = bk_core.request.get_request_path()
                        assert.is_equal(path, "/echo/")
                    end
                )

                it(
                    "empty", function()
                        CTX(
                            {
                                real_request_uri = "",
                            }
                        )

                        local path = bk_core.request.get_request_path()
                        assert.is_equal(path, "")
                    end
                )
            end
        )
    end
)
