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
local utils = require("apisix.plugins.bk-components.utils")


describe(
    "utils",
    function()
        before_each(require("busted_resty").clear)

        context(
            "parse_response",
            function()
                it(
                    "res or res.body is empty",
                    function()
                        local result, err = utils.parse_response(nil, "error", true)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")

                        local result, err = utils.parse_response({body = nil}, "error", true)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                    end
                )

                it(
                    "raise_for_status and status is not 200",
                    function()
                        local result, err = utils.parse_response({body = '{}', status = 500}, nil, true)
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "status code is"))
                    end
                )

                it(
                    "do not raise_for_status and status is not 200",
                    function()
                        local result, err = utils.parse_response({body = '{"foo": "bar"}', status = 500}, nil, false)
                        assert.is_same(result, {foo = "bar"})
                        assert.is_nil(err)
                    end
                )

                it(
                    "body is not json",
                    function()
                        local result, err = utils.parse_response({body = "not valid json", status = 200}, true)
                        assert.is_nil(result)
                        assert.is_equal(err, "response is not valid json")
                    end
                )

                it(
                    "ok",
                    function()
                        local result, err = utils.parse_response({body = '{"foo": "bar"}', status = 200}, true)
                        assert.is_same(result, {foo = "bar"})
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "parse_response_json",
            function()
                it(
                    "body is nil",
                    function()
                        local result, err = utils.parse_response_json(nil)
                        assert.is_nil(result)
                        assert.is_equal(err, "response body is empty")
                    end
                )

                it(
                    "body is not valid json",
                    function()
                        local result, err = utils.parse_response_json("not valid json")
                        assert.is_nil(result)
                        assert.is_equal(err, "response is not valid json")
                    end
                )

                it(
                    "body is valid json",
                    function()
                        local result, err = utils.parse_response_json('{"foo": "bar"}')
                        assert.is_same(result, {foo = "bar"})
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "handle_request",
            function()
                local response, response_err

                before_each(
                    function()
                        response = nil
                        response_err = nil

                        stub(
                            http, "new", function()
                                return {
                                    set_timeout = function() end,
                                    request_uri = function()
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

                it(
                    "request returns timeout and retries",
                    function()
                        local call_count = 0
                        stub(http, "new", function()
                            return {
                                set_timeout = function() end,
                                request_uri = function()
                                    call_count = call_count + 1
                                    if call_count == 1 then
                                        return nil, "timeout"
                                    else
                                        return {status = 200, body = '{"foo": "bar"}'}, nil
                                    end
                                end,
                            }
                        end)

                        local res, err = utils.handle_request("http://example.com", {}, 5000, true)
                        assert.is_same(res, {status = 200, body = '{"foo": "bar"}'})
                        assert.is_nil(err)

                    end
                )


                it(
                    "request returns connection refused",
                    function()
                        response = nil
                        response_err = "connection refused"

                        local res, err = utils.handle_request("http://example.com", {}, 5000, true)
                        assert.is_nil(res)
                        assert.is_equal(err, "connection refused")
                    end
                )

                it(
                    "request returns error",
                    function()
                        response = nil
                        response_err = "mocked error"

                        local res, err = utils.handle_request("http://example.com", {}, 5000, true)
                        assert.is_nil(res)
                        assert.is_equal(err, "mocked error, response: nil")
                    end
                )

                it(
                    "request returns non-200 status with raise_for_status",
                    function()
                        response = {status = 500, body = '{"foo": "bar"}'}
                        response_err = nil

                        local res, err = utils.handle_request("http://example.com", {}, 5000, true)
                        assert.is_nil(res)
                        assert.is_equal(err, "status is 500, not 200")
                    end
                )

                it(
                    "request returns non-200 status without raise_for_status",
                    function()
                        response = {status = 500, body = '{"foo": "bar"}'}
                        response_err = nil

                        local res, err = utils.handle_request("http://example.com", {}, 5000, false)
                        assert.is_same(res, {status = 500, body = '{"foo": "bar"}'})
                        assert.is_nil(err)
                    end
                )

                it(
                    "request returns 200 status",
                    function()
                        response = {status = 200, body = '{"foo": "bar"}'}
                        response_err = nil

                        local res, err = utils.handle_request("http://example.com", {}, 5000, true)
                        assert.is_same(res, {status = 200, body = '{"foo": "bar"}'})
                        assert.is_nil(err)
                    end
                )
            end
        )
    end
)
