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
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")
local plugin = require("apisix.plugins.bk-delete-sensitive")

local ngx = ngx

describe(
    "bk-delete-sensitive", function()

        local uri_args
        local json_body
        local form_data
        local sensitive_keys = {
            "bk_app_secret",
            "access_token",
        }
        local unfiltered_sensitive_keys

        before_each(
            function()
                unfiltered_sensitive_keys = {}

                stub(ngx.req, "clear_header")
                stub(
                    core.request, "get_uri_args", function()
                        return uri_args
                    end
                )
                stub(
                    bk_core.request, "get_json_body", function()
                        return json_body
                    end
                )
                stub(
                    bk_core.request, "get_form_data", function()
                        return form_data
                    end
                )
                stub(core.request, "set_uri_args")
                stub(ngx.req, "set_body_data")
            end
        )

        after_each(
            function()
                uri_args = nil
                json_body = nil
                form_data = nil

                ngx.req.clear_header:revert()
                core.request.get_uri_args:revert()
                bk_core.request.get_json_body:revert()
                bk_core.request.get_form_data:revert()
                core.request.set_uri_args:revert()
                ngx.req.set_body_data:revert()
            end
        )

        context(
            "delete_sensitive_params", function()
                it(
                    "querystring, has sensitive", function()
                        uri_args = {
                            bk_app_secret = "fake-secret",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            {}, {
                                foo = "bar",
                            }
                        )
                        assert.stub(ngx.req.set_body_data).was_not_called()
                    end
                )

                it(
                    "querystring, has no sensitive", function()
                        uri_args = {
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_not_called()
                        assert.stub(ngx.req.set_body_data).was_not_called()
                    end
                )

                it(
                    "form data, has sensitive", function()
                        form_data = {
                            bk_app_secret = "fake-secret",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_not_called()
                        assert.stub(ngx.req.set_body_data).was_called_with("foo=bar")
                    end
                )

                it(
                    "form data, has no sensitive", function()
                        form_data = {
                            a = "b",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_not_called()
                        assert.stub(ngx.req.set_body_data).was_not_called()
                    end
                )

                it(
                    "json data, has sensitive", function()
                        json_body = {
                            bk_app_secret = "fake-secret",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_not_called()
                        assert.stub(ngx.req.set_body_data).was_called_with("{\"foo\":\"bar\"}")
                    end
                )

                it(
                    "json data, has no sensitive", function()
                        json_body = {
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_not_called()
                        assert.stub(ngx.req.set_body_data).was_not_called()
                    end
                )

                it(
                    "has multiple sensitive, uri_args and json_body", function()
                        uri_args = {
                            bk_app_secret = "fake-secret",
                            access_token = "fake-token",
                            foo = "bar",
                        }
                        json_body = {
                            bk_app_secret = "fake-secret",
                            access_token = "fake-token",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            {}, {
                                foo = "bar",
                            }
                        )
                        assert.stub(ngx.req.set_body_data).was_called_with("{\"foo\":\"bar\"}")
                    end
                )

                it(
                    "has multiple sensitive, uri_args and form_data", function()
                        uri_args = {
                            bk_app_secret = "fake-secret",
                            access_token = "fake-token",
                            foo = "bar",
                        }
                        form_data = {
                            bk_app_secret = "fake-secret",
                            access_token = "fake-token",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            {}, {
                                foo = "bar",
                            }
                        )
                        assert.stub(ngx.req.set_body_data).was_called_with("foo=bar")
                    end
                )

                it(
                    "unfiltered sensitive", function()
                        unfiltered_sensitive_keys = {
                            "bk_app_secret",
                        }
                        uri_args = {
                            bk_app_secret = "fake-secret",
                            access_token = "fake-token",
                            foo = "bar",
                        }
                        plugin._delete_sensitive_params({}, sensitive_keys, unfiltered_sensitive_keys)
                        assert.stub(core.request.set_uri_args).was_called_with(
                            {}, {
                                bk_app_secret = "fake-secret",
                                foo = "bar",
                            }
                        )
                    end
                )
            end
        )

        context(
            "delete_sensitive_headers", function()
                it(
                    "ok", function()
                        plugin._delete_sensitive_headers()

                        assert.stub(ngx.req.clear_header).was_called_with("X-Request-Uri")
                        assert.stub(ngx.req.clear_header).was_called_with("X-Bkapi-Authorization")
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                    end
                )

                it(
                    "delete sensitive params", function()
                        ctx.var.bk_api_auth = context_api_bkauth.new(
                            {
                                api_type = 10,
                            }
                        )
                        uri_args = {
                            bk_app_secret = "fake-secret",
                            foo = "bar",
                        }

                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_called_with(
                            ctx, {
                                foo = "bar",
                            }
                        )
                    end
                )

                it(
                    "does not need to delete sensitive params", function()
                        ctx.var.bk_api_auth = context_api_bkauth.new(
                            {
                                api_type = 0,
                            }
                        )
                        uri_args = {
                            bk_app_secret = "fake-secret",
                            foo = "bar",
                        }

                        plugin.rewrite({}, ctx)

                        assert.stub(core.request.set_uri_args).was_not_called()
                    end
                )

                it(
                    "delete sensitive headers", function()
                        plugin.rewrite({}, ctx)

                        assert.stub(ngx.req.clear_header).was_called_with("X-Request-Uri")
                        assert.stub(ngx.req.clear_header).was_called_with("X-Bkapi-Authorization")
                    end
                )
            end
        )
    end
)
