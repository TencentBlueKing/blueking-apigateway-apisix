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
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-delete-sensitive")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 2: enable bk-delete-sensitive plugin using admin api
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-stage-context": {
                            "bk_gateway_name": "demo",
                            "bk_stage_name": "prod",
                            "jwt_private_key": "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            "bk_api_auth": {
                                "api_type": 10,
                                "unfiltered_sensitive_keys": {}
                            }
                        },
                        "bk-delete-sensitive": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
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

=== TEST 3: delete header x-bkapi-authorization
--- request
GET /echo
--- more_headers
x-bkapi-authorization: {"bk_app_code": "demo", "bk_app_secret": "secret"}
foo: bar
--- response_headers
!x-bkapi-authorization
foo: bar

=== TEST 4: delete sensitive params
--- request
POST /echo
{"bk_app_code": "demo", "bk_app_secret": "secret", "access_token": "token"}
--- response_body chomp
{"bk_app_code":"demo"}

=== TEST 5: enable plugin, api_type=0, will not delete sensitive params
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-stage-context": {
                            "bk_gateway_name": "demo",
                            "bk_stage_name": "prod",
                            "jwt_private_key": "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            "bk_api_auth": {
                                "api_type": 0,
                                "unfiltered_sensitive_keys": {}
                            }
                        },
                        "bk-delete-sensitive": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
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

=== TEST 6: api_type=0, will not delete sensitive params
--- request
POST /echo
{"bk_app_code":"demo", "bk_app_secret":"secret"}
--- response_body chomp
{"bk_app_code":"demo", "bk_app_secret":"secret"}

=== TEST 7: enable plugin, api_type=10 and unfiltered_sensitive_keys exist, will not delete sensitive params
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-stage-context": {
                            "bk_gateway_name": "demo",
                            "bk_stage_name": "prod",
                            "jwt_private_key": "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            "bk_api_auth": {
                                "api_type": 10,
                                "unfiltered_sensitive_keys": ["access_token"]
                            }
                        },
                        "bk-delete-sensitive": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
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

=== TEST 8: unfiltered_sensitive_keys exist, will not delete sensitive params
--- request
POST /echo
{"access_token":"token"}
--- response_body chomp
{"access_token":"token"}

=== TEST 9: enable plugin, allow_delete_sensitive_params=false, will not delete sensitive params
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-stage-context": {
                            "bk_gateway_name": "demo",
                            "bk_stage_name": "prod",
                            "jwt_private_key": "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            "bk_api_auth": {
                                "api_type": 10,
                                "allow_delete_sensitive_params": false,
                                "unfiltered_sensitive_keys": {}
                            }
                        },
                        "bk-delete-sensitive": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
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

=== TEST 10: allow_delete_sensitive_params=false, will not delete sensitive params
--- request
POST /echo
{"bk_app_code":"demo", "bk_app_secret":"secret", "access_token":"token"}
--- response_body chomp
{"bk_app_code":"demo", "bk_app_secret":"secret", "access_token":"token"}


=== TEST 11: enable plugin to test auth_params_location
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-stage-context": {
                            "bk_gateway_name": "demo",
                            "bk_stage_name": "prod",
                            "jwt_private_key": "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            "bk_api_auth": {
                                "api_type": 10,
                                "allow_delete_sensitive_params": true,
                                "unfiltered_sensitive_keys": {}
                            }
                        },
                        "bk-resource-context": {
                            "bk_resource_name": "echo",
                            "bk_resource_auth": {
                                "verified_app_required": false,
                                "verified_user_required": false,
                                "resource_perm_required": false,
                                "skip_user_verification": true
                            }
                        },
                        "bk-auth-verify": {},
                        "bk-delete-sensitive": {},
                        "file-logger": {
                            "path": "file.log",
                            "log_format": {
                                "auth_location": "$auth_params_location"
                            }
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

=== TEST 12: auth_params_location maybe changed to header_and_params if sensitive params exist in request params
--- config
    location /t {
        content_by_lua_block {
            os.remove("file.log")

            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            -- auth-params in header, and sensitive params exist in request params
            t("/hello?bk_app_code=demo&bk_app_secret=secret", ngx.HTTP_GET, nil, nil, {
                ["x-bkapi-authorization"] = '{"bk_app_code": "demo"}'
            })
            -- auth-params in header, but sensitive params do not exist in request params
            t("/hello?bk_app_code=demo", ngx.HTTP_GET, nil, nil, {
                ["x-bkapi-authorization"] = '{"bk_app_code": "demo"}'
            })
            -- auth-params only in params
            t("/hello?bk_app_secret=secret", ngx.HTTP_GET)

            local fd, err = io.open("file.log", "r")

            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end

            local line1 = fd:read()
            local line2 = fd:read()
            local line3 = fd:read()

            local new_line1 = core.json.decode(line1)
            local new_line2 = core.json.decode(line2)
            local new_line3 = core.json.decode(line3)
            ngx.say(new_line1.auth_location)
            ngx.say(new_line2.auth_location)
            ngx.say(new_line3.auth_location)
        }
    }
--- response_body
header_and_params
header
params
