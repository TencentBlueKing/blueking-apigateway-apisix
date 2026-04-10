#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) 2025 Tencent. All rights reserved.
# Licensed under the MIT License (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
#     http://opensource.org/licenses/MIT
#
# Unless required by applicable law or agreed to in writing, software distributed under
# the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific language governing permissions and
# limitations under the License.
#
# We undertake not to change the open source license (MIT license) applicable
# to the current version of the project delivered to anyone in the future.
#

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: schema sanity - valid config
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-content-moderation")
            local ok, err = plugin.check_schema({
                endpoint = "https://green-cip.cn-shanghai.aliyuncs.com",
                region_id = "cn-shanghai",
                access_key_id = "test-key-id",
                access_key_secret = "test-key-secret",
                check_request = true,
                risk_level_bar = "high"
            })
            if not ok then
                ngx.say(err)
                return
            end
            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 2: schema sanity - missing required fields
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-content-moderation")
            local ok, err = plugin.check_schema({
                endpoint = "https://example.com"
            })
            if not ok then
                ngx.say("rejected: missing fields")
                return
            end
            ngx.say("should not reach here")
        }
    }
--- response_body
rejected: missing fields

=== TEST 3: schema sanity - response plugin accepts empty
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-content-moderation-response")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
                return
            end
            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 4: request moderation - skip when check_request is false
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-content-moderation": {
                            "endpoint": "https://green-cip.cn-shanghai.aliyuncs.com",
                            "region_id": "cn-shanghai",
                            "access_key_id": "test-key-id",
                            "access_key_secret": "test-key-secret",
                            "check_request": false,
                            "check_response": false
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/hello"
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 5: request moderation - pass through when check disabled
--- request
GET /hello
--- response_body
hello world

=== TEST 6: aliyun client - risk_level_to_int
--- config
    location /t {
        content_by_lua_block {
            local aliyun = require("apisix.plugins.bk-content-moderation.aliyun_text_moderation")
            ngx.say("none=", aliyun.risk_level_to_int("none"))
            ngx.say("low=", aliyun.risk_level_to_int("low"))
            ngx.say("medium=", aliyun.risk_level_to_int("medium"))
            ngx.say("high=", aliyun.risk_level_to_int("high"))
            ngx.say("max=", aliyun.risk_level_to_int("max"))
            ngx.say("unknown=", aliyun.risk_level_to_int("unknown"))
        }
    }
--- response_body
none=0
low=1
medium=2
high=3
max=4
unknown=-1

=== TEST 7: aliyun client - url_encoding encodes sub-delimiters
--- config
    location /t {
        content_by_lua_block {
            local aliyun = require("apisix.plugins.bk-content-moderation.aliyun_text_moderation")
            local encoded = aliyun.url_encoding("test!value")
            if encoded:find("%%21") then
                ngx.say("encoded correctly")
            else
                ngx.say("encoding failed: ", encoded)
            end
        }
    }
--- response_body
encoded correctly

=== TEST 8: aliyun client - calculate_sign is deterministic
--- config
    location /t {
        content_by_lua_block {
            local aliyun = require("apisix.plugins.bk-content-moderation.aliyun_text_moderation")
            local params = {
                ["AccessKeyId"] = "test-key",
                ["Action"] = "TextModerationPlus",
            }
            local sig1 = aliyun.calculate_sign(params, "secret&")
            local sig2 = aliyun.calculate_sign(params, "secret&")
            if sig1 == sig2 and #sig1 > 0 then
                ngx.say("deterministic")
            else
                ngx.say("not deterministic")
            end
        }
    }
--- response_body
deterministic
