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

local plugin = require("apisix.plugins.bk-content-moderation-response")


describe("bk-content-moderation-response", function()
    local ctx

    before_each(function()
        ctx = {
            var = {},
        }
    end)

    context("check schema", function()
        it("should accept empty config", function()
            assert.is_true(plugin.check_schema({}))
        end)
    end)

    context("access", function()
        it("should return nil when no moderation conf in ctx", function()
            local code = plugin.access({}, ctx)
            assert.is_nil(code)
        end)

        it("should return nil when check_response is false", function()
            ctx._content_moderation_conf = {
                check_response = false,
            }
            local code = plugin.access({}, ctx)
            assert.is_nil(code)
        end)

        it("should return nil when check_response is nil", function()
            ctx._content_moderation_conf = {
                endpoint = "https://example.com",
            }
            local code = plugin.access({}, ctx)
            assert.is_nil(code)
        end)
    end)

    context("build_upstream_url", function()
        it("should return error when no matched_upstream", function()
            local result, err = plugin._build_upstream_url(ctx)
            assert.is_nil(result)
            assert.is_true(
                err:find("no matched upstream") ~= nil
            )
        end)

        it("should return error when no nodes", function()
            ctx.matched_upstream = {}
            local result, err = plugin._build_upstream_url(ctx)
            assert.is_nil(result)
            assert.is_true(
                err:find("no upstream nodes") ~= nil
            )
        end)

        it("should parse array-style nodes", function()
            ctx.matched_upstream = {
                scheme = "http",
                nodes = {
                    { host = "127.0.0.1", port = 8080, weight = 1 },
                },
            }
            ctx.var.upstream_host = "example.com"
            ctx.var.upstream_uri = "/api/v1/test"

            local result, err = plugin._build_upstream_url(ctx)
            assert.is_nil(err)
            assert.is_not_nil(result)
            assert.is_equal("http", result.scheme)
            assert.is_equal("127.0.0.1", result.host)
            assert.is_equal(8080, result.port)
            assert.is_equal("example.com", result.upstream_host)
            assert.is_equal("/api/v1/test", result.uri)
        end)

        it("should parse map-style nodes", function()
            ctx.matched_upstream = {
                scheme = "https",
                nodes = {
                    ["10.0.0.1:443"] = 1,
                },
            }
            ctx.var.uri = "/hello"

            local result, err = plugin._build_upstream_url(ctx)
            assert.is_nil(err)
            assert.is_not_nil(result)
            assert.is_equal("https", result.scheme)
            assert.is_equal("10.0.0.1", result.host)
            assert.is_equal(443, result.port)
            assert.is_equal("/hello", result.uri)
        end)

        it("should default scheme to http", function()
            ctx.matched_upstream = {
                nodes = {
                    { host = "127.0.0.1", port = 80, weight = 1 },
                },
            }

            local result, err = plugin._build_upstream_url(ctx)
            assert.is_nil(err)
            assert.is_equal("http", result.scheme)
        end)
    end)

    context("is_streaming_response", function()
        it("should detect SSE content type", function()
            local res = {
                headers = {
                    ["Content-Type"] = "text/event-stream",
                },
            }
            assert.is_true(plugin._is_streaming_response(res))
        end)

        it("should detect chunked non-JSON", function()
            local res = {
                headers = {
                    ["Content-Type"] = "text/plain",
                    ["Transfer-Encoding"] = "chunked",
                },
            }
            assert.is_true(plugin._is_streaming_response(res))
        end)

        it("should not detect chunked JSON as streaming", function()
            local res = {
                headers = {
                    ["Content-Type"] = "application/json",
                    ["Transfer-Encoding"] = "chunked",
                },
            }
            assert.is_false(plugin._is_streaming_response(res))
        end)

        it("should not detect plain response as streaming", function()
            local res = {
                headers = {
                    ["Content-Type"] = "application/json",
                },
            }
            assert.is_false(plugin._is_streaming_response(res))
        end)
    end)
end)
