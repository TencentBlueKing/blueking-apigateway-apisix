#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) Tencent. All rights reserved.
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

    my $extra_init_by_lua = <<'_EOC_';
        local resolver = require("apisix.core.resolver")
        local original_parse_domain = resolver.parse_domain
        resolver.parse_domain = function(host)
            if host == "invalid_domain" then
                return nil, "test DNS lookup failed"
            end
            return original_parse_domain(host)
        end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);
});

run_tests;

__DATA__

=== TEST 1: add route with a domain that has no valid IP
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/server_port",
                    "upstream": {
                        "key": "remote_addr",
                        "type": "chash",
                        "nodes": {
                            "invalid_domain:1980": 1
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: return the BlueKing 502 contract when no valid IP is found
--- request
GET /server_port
--- error_code: 502
--- response_body_like eval
qr/"code":1650200/
--- error_log
parse domain for nodes:
--- timeout: 10
