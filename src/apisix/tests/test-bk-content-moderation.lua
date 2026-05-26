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
local plugin = require("apisix.plugins.bk-content-moderation")
local aliyun = require(
    "apisix.plugins.bk-content-moderation.aliyun_text_moderation"
)


describe("bk-content-moderation", function()
    local ctx, conf

    before_each(function()
        ctx = {
            var = {},
        }

        conf = {
            endpoint = "https://green-cip.cn-shanghai.aliyuncs.com",
            region_id = "cn-shanghai",
            access_key_id = "test-key-id",
            access_key_secret = "test-key-secret",
            check_request = true,
            request_check_service = "llm_query_moderation",
            request_check_length_limit = 2000,
            check_response = false,
            risk_level_bar = "high",
            timeout = 5000,
        }
    end)

    context("check schema", function()
        it("should reject empty config", function()
            assert.is_false(plugin.check_schema({}))
        end)

        it("should reject missing required fields", function()
            assert.is_false(plugin.check_schema({
                endpoint = "https://example.com",
            }))
        end)

        it("should accept valid config", function()
            assert.is_true(plugin.check_schema(conf))
        end)

        it("should accept config with response checking", function()
            conf.check_response = true
            conf.stream_check_mode = "realtime"
            assert.is_true(plugin.check_schema(conf))
        end)

        it("should reject invalid risk_level_bar", function()
            conf.risk_level_bar = "invalid"
            assert.is_false(plugin.check_schema(conf))
        end)

        it("should reject invalid stream_check_mode", function()
            conf.stream_check_mode = "invalid"
            assert.is_false(plugin.check_schema(conf))
        end)
    end)

    context("access", function()
        it("should store conf in ctx for response plugin", function()
            conf.check_request = false
            plugin.access(conf, ctx)
            assert.is_equal(conf, ctx._content_moderation_conf)
        end)

        it("should skip when check_request is false", function()
            conf.check_request = false
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
        end)

        it("should pass when request body is empty", function()
            stub(ngx.req, "read_body")
            stub(ngx.req, "get_body_data", function()
                return nil
            end)
            stub(ngx.req, "get_body_file", function()
                return nil
            end)

            local code = plugin.access(conf, ctx)
            assert.is_nil(code)

            ngx.req.read_body:revert()
            ngx.req.get_body_data:revert()
            ngx.req.get_body_file:revert()
        end)

        it("should block when content is risky", function()
            stub(ngx.req, "read_body")
            stub(ngx.req, "get_body_data", function()
                return "some risky content"
            end)
            stub(aliyun, "check_content", function()
                return true, "violation detected", "high"
            end)

            local code = plugin.access(conf, ctx)
            assert.is_equal(403, code)
            assert.is_not_nil(ctx.var.bk_apigw_error)
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.code_name,
                    "CONTENT_BLOCKED_BY_MODERATION"
                ) ~= nil
            )

            ngx.req.read_body:revert()
            ngx.req.get_body_data:revert()
            aliyun.check_content:revert()
        end)

        it("should pass when content is safe", function()
            stub(ngx.req, "read_body")
            stub(ngx.req, "get_body_data", function()
                return "some safe content"
            end)
            stub(aliyun, "check_content", function()
                return false, nil, "none"
            end)

            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)

            ngx.req.read_body:revert()
            ngx.req.get_body_data:revert()
            aliyun.check_content:revert()
        end)

        it("should pass and log when moderation API fails", function()
            stub(ngx.req, "read_body")
            stub(ngx.req, "get_body_data", function()
                return "some content"
            end)
            stub(aliyun, "check_content", function()
                return nil, "connection refused", nil
            end)

            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)

            ngx.req.read_body:revert()
            ngx.req.get_body_data:revert()
            aliyun.check_content:revert()
        end)
    end)
end)


describe("aliyun_text_moderation", function()
    context("risk_level_to_int", function()
        it("should return correct values", function()
            assert.is_equal(0, aliyun.risk_level_to_int("none"))
            assert.is_equal(1, aliyun.risk_level_to_int("low"))
            assert.is_equal(2, aliyun.risk_level_to_int("medium"))
            assert.is_equal(3, aliyun.risk_level_to_int("high"))
            assert.is_equal(4, aliyun.risk_level_to_int("max"))
            assert.is_equal(-1, aliyun.risk_level_to_int("unknown"))
        end)
    end)

    context("url_encoding", function()
        it("should encode sub-delimiters per RFC 3986", function()
            local encoded = aliyun.url_encoding("hello!")
            assert.is_not_nil(string.find(encoded, "%%21"))
        end)

        it("should encode parentheses", function()
            local encoded = aliyun.url_encoding("func(arg)")
            assert.is_not_nil(string.find(encoded, "%%28"))
            assert.is_not_nil(string.find(encoded, "%%29"))
        end)

        it("should encode asterisk", function()
            local encoded = aliyun.url_encoding("a*b")
            assert.is_not_nil(string.find(encoded, "%%2A"))
        end)
    end)

    context("calculate_sign", function()
        it("should produce a non-empty base64 signature", function()
            local params = {
                ["AccessKeyId"] = "test-key",
                ["Action"] = "TextModerationPlus",
                ["Format"] = "JSON",
            }
            local sig = aliyun.calculate_sign(params, "test-secret&")
            assert.is_not_nil(sig)
            assert.is_true(#sig > 0)
        end)

        it("should be deterministic", function()
            local params = {
                ["AccessKeyId"] = "key1",
                ["Action"] = "Test",
            }
            local sig1 = aliyun.calculate_sign(params, "secret&")
            local sig2 = aliyun.calculate_sign(params, "secret&")
            assert.is_equal(sig1, sig2)
        end)
    end)
end)
