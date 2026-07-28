# OAuth2 App Code Validation Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `bk-oauth2-appcode-validate`, a fail-closed APISIX plugin that permits OAuth2 requests only for globally enabled `public` and `personal` application codes.

**Architecture:** The plugin reads two boolean APISIX `plugin_attr` values during `_M.init()` and rebuilds a module-level hash-set on every initialization. Its `rewrite` handler skips non-OAuth2 traffic, validates `ctx.var.bk_app_code` after audience validation, and returns a rich 401 `invalid_token` response when the code is unsupported.

**Tech Stack:** LuaJIT/OpenResty, Apache APISIX 3.17 plugin APIs, `bk-core.errorx`, `bk-core.oauth2`, Busted, test-nginx, Make, Docker.

## Global Constraints

- Work only in `/root/workspace/tx/wklken/blueking-apigateway-apisix/.worktrees/feat-upgrade-apisix-3.17-codex-20260723`.
- Preserve the existing uncommitted change in `src/apisix/plugins/bk-oauth2-protected-resource.lua`; never stage, edit, or commit it.
- Plugin name is exactly `bk-oauth2-appcode-validate`.
- Plugin priority is exactly `17677`, after `bk-oauth2-audience-validate` at `17678`.
- `support_public` and `support_personal` are global `plugin_attr` booleans and both default to `false`.
- Missing or invalid attributes fail closed with an empty allowlist.
- Only `public` and `personal` can ever be allowed; ordinary application codes remain unsupported.
- Non-OAuth2 requests must be skipped without changing the request.
- Rejections use HTTP 401, APIGW `UNAUTHORIZED`, and `WWW-Authenticate` error `invalid_token`.
- Logs and caller errors include the requested app code plus both support statuses, but never include an access token or credential.
- Add no dependency and make no unrelated refactor.
- Use test-first red/green cycles and stage only the files named by each task.

---

## File Map

- Create `src/apisix/plugins/bk-oauth2-appcode-validate.lua`: attribute initialization, allowlist state, request validation, logs, and caller error.
- Create `src/apisix/tests/test-bk-oauth2-appcode-validate.lua`: Busted coverage for schemas, initialization/reload, allow/deny behavior, error details, and logs.
- Create `src/apisix/t/bk-oauth2-appcode-validate.t`: test-nginx coverage using real per-case `plugin_attr`.
- Modify `src/apisix/plugins/README.md`: register the plugin at priority `17677`.

### Shared Plugin Interfaces

The implementation tasks use these exact interfaces:

```lua
plugin.check_schema(conf) -> boolean, string|nil
plugin.init() -> nil
plugin.rewrite(conf, ctx) -> nil | 401, string
plugin.attr_schema -> table
plugin._get_validation_state() -> {
    support_public = boolean,
    support_personal = boolean,
    allowed_app_codes = table<string, boolean>,
}
```

`_get_validation_state` is exported only when `_TEST` is true.

---

### Task 1: Implement Initialization and Request Validation with Busted

**Files:**
- Create: `src/apisix/plugins/bk-oauth2-appcode-validate.lua`
- Create: `src/apisix/tests/test-bk-oauth2-appcode-validate.lua`

**Interfaces:**
- Consumes: `apisix.plugin.plugin_attr(name)`, `ctx.var.is_bk_oauth2`, `ctx.var.bk_app_code`, `errorx.new_general_unauthorized()`, and `oauth2.build_www_authenticate_header(ctx, code, description)`.
- Produces: the shared plugin interfaces defined above and a rewrite-phase plugin with priority `17677`.

- [ ] **Step 1: Write the failing Busted contract**

Create `src/apisix/tests/test-bk-oauth2-appcode-validate.lua` with this content:

```lua
--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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
local apisix_plugin = require("apisix.plugin")
local bk_core = require("apisix.plugins.bk-core.init")
local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")

describe(
    "bk-oauth2-appcode-validate", function()
        local plugin_attr
        local ctx

        before_each(
            function()
                plugin_attr = {}
                ctx = {
                    var = {
                        uri = "/api/test",
                        bk_gateway_name = "demo",
                        is_bk_oauth2 = true,
                        bk_app_code = "public",
                    },
                }

                stub(
                    apisix_plugin, "plugin_attr", function(name)
                        assert.is_equal("bk-oauth2-appcode-validate", name)
                        return plugin_attr
                    end
                )
                stub(
                    bk_core.config, "get_bk_apigateway_api_tmpl", function()
                        return "https://{api_name}.example.com"
                    end
                )
                stub(core.log, "info")
                stub(core.log, "error")

                plugin.init()
            end
        )

        after_each(
            function()
                apisix_plugin.plugin_attr:revert()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
                core.log.info:revert()
                core.log.error:revert()
                ngx.header["WWW-Authenticate"] = nil
            end
        )

        context(
            "schema", function()
                it(
                    "accepts empty route configuration", function()
                        local ok, err = plugin.check_schema({})

                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "accepts boolean plugin attributes", function()
                        local ok, err = core.schema.check(
                            plugin.attr_schema,
                            {
                                support_public = true,
                                support_personal = false,
                            }
                        )

                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "rejects non-boolean plugin attributes", function()
                        local ok = core.schema.check(
                            plugin.attr_schema,
                            {
                                support_public = "true",
                            }
                        )

                        assert.is_false(ok)
                    end
                )
            end
        )

        context(
            "initialization", function()
                it(
                    "defaults to an empty allowlist", function()
                        local state = plugin._get_validation_state()

                        assert.is_false(state.support_public)
                        assert.is_false(state.support_personal)
                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_nil(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "allows public when configured", function()
                        plugin_attr = {
                            support_public = true,
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_true(state.support_public)
                        assert.is_false(state.support_personal)
                        assert.is_true(state.allowed_app_codes.public)
                        assert.is_nil(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "allows personal when configured", function()
                        plugin_attr = {
                            support_personal = true,
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_false(state.support_public)
                        assert.is_true(state.support_personal)
                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_true(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "allows both supported app codes", function()
                        plugin_attr = {
                            support_public = true,
                            support_personal = true,
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_true(state.allowed_app_codes.public)
                        assert.is_true(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "logs the effective initialization state", function()
                        plugin_attr = {
                            support_public = true,
                        }

                        plugin.init()

                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: initialized",
                            ", support_public=", true,
                            ", support_personal=", false,
                            ", allowed_app_codes=", '{"public":true}'
                        )
                    end
                )

                it(
                    "fails closed for invalid plugin attributes", function()
                        plugin_attr = {
                            support_public = "true",
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_false(state.support_public)
                        assert.is_false(state.support_personal)
                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_nil(state.allowed_app_codes.personal)
                        assert.stub(core.log.error).was_called()
                    end
                )

                it(
                    "does not retain stale allowlist entries after reinitialization", function()
                        plugin_attr = {
                            support_public = true,
                        }
                        plugin.init()

                        plugin_attr = {
                            support_personal = true,
                        }
                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_true(state.allowed_app_codes.personal)
                    end
                )
            end
        )

        context(
            "rewrite", function()
                it(
                    "skips when is_bk_oauth2 is false", function()
                        ctx.var.is_bk_oauth2 = false

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "skips when is_bk_oauth2 is absent", function()
                        ctx.var.is_bk_oauth2 = nil

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "allows public when public support is enabled", function()
                        plugin_attr = {
                            support_public = true,
                        }
                        plugin.init()

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: validation passed",
                            ", bk_app_code=", "public",
                            ", support_public=", true,
                            ", support_personal=", false
                        )
                    end
                )

                it(
                    "allows personal when personal support is enabled", function()
                        plugin_attr = {
                            support_personal = true,
                        }
                        plugin.init()
                        ctx.var.bk_app_code = "personal"

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "rejects a disabled supported app code", function()
                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                        assert.is_equal(
                            "UNAUTHORIZED",
                            ctx.var.bk_apigw_error.error.code_name
                        )
                    end
                )

                it(
                    "rejects an ordinary app code even when both flags are enabled", function()
                        plugin_attr = {
                            support_public = true,
                            support_personal = true,
                        }
                        plugin.init()
                        ctx.var.bk_app_code = "ordinary-app"

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "rejects a missing app code", function()
                        ctx.var.bk_app_code = nil

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "rejects an empty app code", function()
                        ctx.var.bk_app_code = ""

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "returns rich invalid_token details", function()
                        plugin_attr = {
                            support_personal = true,
                        }
                        plugin.init()
                        ctx.var.bk_app_code = "public"

                        local status = plugin.rewrite({}, ctx)
                        local message = ctx.var.bk_apigw_error.error.message
                        local www_auth = ngx.header["WWW-Authenticate"]

                        assert.is_equal(401, status)
                        assert.is_truthy(string.find(
                            message,
                            'reason="OAuth2 token app code is not allowed"',
                            1,
                            true
                        ))
                        assert.is_truthy(string.find(message, 'bk_app_code="public"', 1, true))
                        assert.is_truthy(string.find(message, 'support_public="false"', 1, true))
                        assert.is_truthy(string.find(message, 'support_personal="true"', 1, true))
                        assert.is_truthy(string.find(www_auth, 'error="invalid_token"', 1, true))
                        assert.is_truthy(string.find(www_auth, "bk_app_code=public", 1, true))
                        assert.is_truthy(string.find(www_auth, "support_public=false", 1, true))
                        assert.is_truthy(string.find(www_auth, "support_personal=true", 1, true))
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: validation failed",
                            ", bk_app_code=", "public",
                            ", support_public=", false,
                            ", support_personal=", true
                        )
                    end
                )
            end
        )
    end
)
```

- [ ] **Step 2: Run the focused Busted file and confirm the red state**

Run from `src/apisix`:

```bash
docker run --rm \
  -v "$PWD/tests/conf/config.yaml:/usr/local/apisix/conf/config.yaml" \
  -v "$PWD/tests:/bkgateway/tests/" \
  -v "$PWD/logs/:/bkgateway/logs/" \
  -v "$PWD/tests/conf/nginx.conf:/bkgateway/conf/nginx.conf" \
  -v "$PWD/plugins:/bkgateway/apisix/plugins" \
  apisix-test-busted-317 \
  resty -c 4096 --errlog-level error \
  --http-include ./conf/nginx.conf -I . \
  ./tests/busted_runner.lua --verbose \
  --helper ./tests/busted_helper.lua \
  ./tests/test-bk-oauth2-appcode-validate.lua
```

Expected: FAIL while requiring `apisix.plugins.bk-oauth2-appcode-validate`, because the plugin file does not exist.

- [ ] **Step 3: Implement the minimal complete plugin**

Create `src/apisix/plugins/bk-oauth2-appcode-validate.lua` with the standard TencentBlueKing MIT header and this implementation:

```lua
--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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
-- # bk-oauth2-appcode-validate
--
-- Validate whether an OAuth2 token's application code is enabled by plugin attributes.
--
-- This plugin only runs when ctx.var.is_bk_oauth2 == true.
--
-- This plugin depends on:
--     * bk-oauth2-verify: To set ctx.var.bk_app_code
--
local core = require("apisix.core")
local apisix_plugin = require("apisix.plugin")
local errorx = require("apisix.plugins.bk-core.errorx")
local oauth2 = require("apisix.plugins.bk-core.oauth2")
local ngx = ngx
local tostring = tostring

local plugin_name = "bk-oauth2-appcode-validate"

local schema = {
    type = "object",
    properties = {},
}

local attr_schema = {
    type = "object",
    properties = {
        support_public = {
            type = "boolean",
            default = false,
        },
        support_personal = {
            type = "boolean",
            default = false,
        },
    },
}

local _M = {
    version = 0.1,
    priority = 17677,
    name = plugin_name,
    schema = schema,
    attr_schema = attr_schema,
}

local support_public = false
local support_personal = false
local allowed_app_codes = {}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function reset_validation_state()
    support_public = false
    support_personal = false
    allowed_app_codes = {}
end


local function get_validation_state()
    return {
        support_public = support_public,
        support_personal = support_personal,
        allowed_app_codes = allowed_app_codes,
    }
end


function _M.init()
    reset_validation_state()

    local plugin_info = apisix_plugin.plugin_attr(plugin_name) or {}
    local ok, err = core.schema.check(attr_schema, plugin_info)
    if not ok then
        core.log.error(
            "failed to check plugin_attr[", plugin_name, "]: ", err,
            ", fail closed with no allowed app codes"
        )
        return
    end

    support_public = plugin_info.support_public == true
    support_personal = plugin_info.support_personal == true

    if support_public then
        allowed_app_codes.public = true
    end

    if support_personal then
        allowed_app_codes.personal = true
    end

    core.log.info(
        plugin_name .. ": initialized",
        ", support_public=", support_public,
        ", support_personal=", support_personal,
        ", allowed_app_codes=", core.json.encode(allowed_app_codes)
    )
end


local function build_error_description(app_code)
    return "OAuth2 token app code is not allowed: bk_app_code=" .. app_code ..
        ", support_public=" .. tostring(support_public) ..
        ", support_personal=" .. tostring(support_personal)
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    if ctx.var.is_bk_oauth2 ~= true then
        core.log.info(
            plugin_name .. ": skipping",
            ", is_bk_oauth2=", ctx.var.is_bk_oauth2
        )
        return
    end

    local app_code = ctx.var.bk_app_code or ""

    core.log.info(
        plugin_name .. ": checking",
        ", bk_app_code=", app_code,
        ", support_public=", support_public,
        ", support_personal=", support_personal
    )

    if app_code ~= "" and allowed_app_codes[app_code] then
        core.log.info(
            plugin_name .. ": validation passed",
            ", bk_app_code=", app_code,
            ", support_public=", support_public,
            ", support_personal=", support_personal
        )
        return
    end

    core.log.info(
        plugin_name .. ": validation failed",
        ", bk_app_code=", app_code,
        ", support_public=", support_public,
        ", support_personal=", support_personal
    )

    local error_description = build_error_description(app_code)
    local err = errorx.new_general_unauthorized():with_fields(
        {
            reason = "OAuth2 token app code is not allowed",
            bk_app_code = app_code,
            support_public = support_public,
            support_personal = support_personal,
        }
    )

    ngx.header["WWW-Authenticate"] = oauth2.build_www_authenticate_header(
        ctx, "invalid_token", error_description
    )
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._get_validation_state = get_validation_state
end

return _M
```

- [ ] **Step 4: Run the focused Busted file and confirm green**

Repeat the focused Docker command from Step 2.

Expected: the new file reports only successes, with zero failures and zero errors.

- [ ] **Step 5: Run the full Busted suite**

Run from `src/apisix`:

```bash
RUN_WITH_IT= make test-busted
```

Expected: all Busted tests pass with zero failures and zero errors.

- [ ] **Step 6: Commit the plugin and Busted contract**

```bash
git add -- \
  src/apisix/plugins/bk-oauth2-appcode-validate.lua \
  src/apisix/tests/test-bk-oauth2-appcode-validate.lua
git diff --cached --name-status
git diff --cached --check
git commit -m "feat(oauth2): validate supported token app codes"
```

Expected staged files: exactly the plugin and its Busted test. Do not stage `bk-oauth2-protected-resource.lua`.

---

### Task 2: Add Real Plugin-Attribute Functional Coverage

**Files:**
- Create: `src/apisix/t/bk-oauth2-appcode-validate.t`

**Interfaces:**
- Consumes: the plugin created in Task 1 and APISIX `extra_yaml_config`.
- Produces: request-level evidence that APISIX invokes `_M.init()` with real `plugin_attr` and enforces the 401/header contract.

- [ ] **Step 1: Create the test-nginx suite**

Create `src/apisix/t/bk-oauth2-appcode-validate.t` with the following complete content:

```perl
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

=== TEST 1: sanity - schema and priority
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("priority: " .. plugin.priority)
        }
    }
--- response_body
priority: 17677

=== TEST 2: non-OAuth2 requests are skipped
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = false,
                    bk_app_code = "public"
                }
            }

            local result = plugin.rewrite({}, ctx)
            ngx.say(result == nil and "skipped" or "processed")
        }
    }
--- response_body
skipped

=== TEST 3: public-only configuration allows public
--- extra_yaml_config
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: true
    support_personal: false
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local result = plugin.rewrite({}, ctx)
            ngx.say(result == nil and "pass" or "fail")
        }
    }
--- response_body
pass

=== TEST 4: public-only configuration rejects personal
--- extra_yaml_config
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: true
    support_personal: false
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "personal"
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
            ngx.say("code_name: " .. ctx.var.bk_apigw_error.error.code_name)
            ngx.say("message: " .. ctx.var.bk_apigw_error.error.message)
        }
    }
--- response_body_like eval
qr/status: 401\ncode_name: UNAUTHORIZED\nmessage: Unauthorized .*OAuth2 token app code is not allowed.*/
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*bk_app_code=personal.*support_public=true.*support_personal=false"

=== TEST 5: personal-only configuration allows personal
--- extra_yaml_config
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: false
    support_personal: true
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "personal"
                }
            }

            local result = plugin.rewrite({}, ctx)
            ngx.say(result == nil and "pass" or "fail")
        }
    }
--- response_body
pass

=== TEST 6: personal-only configuration rejects public
--- extra_yaml_config
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: false
    support_personal: true
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*support_public=false.*support_personal=true"

=== TEST 7: both-enabled configuration allows both app codes
--- extra_yaml_config
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: true
    support_personal: true
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local public_result = plugin.rewrite({}, ctx)
            ctx.var.bk_app_code = "personal"
            local personal_result = plugin.rewrite({}, ctx)

            ngx.say(public_result == nil and "public: pass" or "public: fail")
            ngx.say(personal_result == nil and "personal: pass" or "personal: fail")
        }
    }
--- response_body
public: pass
personal: pass

=== TEST 8: default configuration rejects every OAuth2 app code
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*support_public=false.*support_personal=false"

=== TEST 9: ordinary app code stays unsupported when both flags are enabled
--- extra_yaml_config
plugin_attr:
  bk-oauth2-appcode-validate:
    support_public: true
    support_personal: true
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "ordinary-app"
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*bk_app_code=ordinary-app.*support_public=true.*support_personal=true"
```

- [ ] **Step 2: Run the focused test-nginx suite**

Run from `src/apisix`:

```bash
RUN_WITH_IT= make test-nginx CASE_FILE=bk-oauth2-appcode-validate.t
```

Expected: `t/bk-00.t` and `t/bk-oauth2-appcode-validate.t` both report `ok`, followed by `Result: PASS`.

- [ ] **Step 3: Commit the functional test**

```bash
git add -- src/apisix/t/bk-oauth2-appcode-validate.t
git diff --cached --name-status
git diff --cached --check
git commit -m "test(oauth2): cover app code validation plugin"
```

Expected staged file: exactly `src/apisix/t/bk-oauth2-appcode-validate.t`.

---

### Task 3: Register the Plugin and Run Completion Gates

**Files:**
- Modify: `src/apisix/plugins/README.md:54`

**Interfaces:**
- Consumes: plugin name and priority from Task 1.
- Produces: repository plugin registry documentation and fresh completion evidence for the entire change.

- [ ] **Step 1: Register the plugin beside audience validation**

In `src/apisix/plugins/README.md`, keep the existing audience line and insert this exact line immediately after it:

```markdown
- bk-oauth2-appcode-validate                # priority: 17677  # OAuth2 app code 验证：按全局配置允许 public 和 personal 客户端
```

- [ ] **Step 2: Verify the new Lua license header**

Run from the repository root:

```bash
make check-license
```

Expected: exit code 0 and a final count of `0` files missing the TencentBlueKing license. If an
unrelated file already fails this repository-wide gate, confirm it also fails on the base branch,
verify the new Lua files directly, and report the pre-existing failure without changing that file.

- [ ] **Step 3: Run lint**

Run from `src/apisix`:

```bash
RUN_WITH_IT= make lint
```

Expected: zero warnings and zero errors.

- [ ] **Step 4: Run the complete APISIX test suite**

Run from `src/apisix`:

```bash
RUN_WITH_IT= make test
```

Expected: Busted reports zero failures/errors, every `t/bk-*.t` file reports `ok`, and test-nginx ends with `Result: PASS`.

- [ ] **Step 5: Audit the intended diff and dirty-file isolation**

Run from the repository root:

```bash
git status --short
git diff --check
git diff --name-status origin/feat/upgrade-apisix-3.17...HEAD
git diff -- src/apisix/plugins/bk-oauth2-protected-resource.lua
```

Expected:

- The implementation history contains only the design/plan documentation and the four in-scope implementation files.
- `src/apisix/plugins/bk-oauth2-protected-resource.lua` remains an unstaged user modification and is absent from every implementation commit.
- No whitespace errors are reported.

- [ ] **Step 6: Commit the registry documentation**

```bash
git add -- src/apisix/plugins/README.md
git diff --cached --name-status
git diff --cached --check
git commit -m "docs(plugins): register OAuth2 app code validation"
```

Expected staged file: exactly `src/apisix/plugins/README.md`.

- [ ] **Step 7: Record final evidence**

Capture these values for the handoff:

```bash
git log --oneline -5
git status --short --branch
git rev-parse HEAD
```

Report:

- Commit IDs for the plugin/Busted, test-nginx, and README commits.
- Focused Busted result.
- Focused test-nginx result.
- `make check-license`, lint, and full test results.
- Confirmation that the pre-existing `bk-oauth2-protected-resource.lua` modification was preserved and excluded.
