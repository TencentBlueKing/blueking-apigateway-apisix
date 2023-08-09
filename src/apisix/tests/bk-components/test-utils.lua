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
    "utils", function()
        before_each(require("busted_resty").clear)

        context(
            "parse_response", function()
                it(
                    "res or res.body is empty", function()
                        local result, err = utils.parse_response(nil, "error", true)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")

                        result, err = utils.parse_response(
                            {
                                body = nil,
                            }, "error", true
                        )
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                    end
                )

                it(
                    "raise_for_status and status is not 200", function()
                        local result, err = utils.parse_response(
                            {
                                body = '{}',
                                status = 500,
                            }, nil, true
                        )
                        assert.is_nil(result)
                        assert.is_true(core.string.has_prefix(err, "status code is"))
                    end
                )

                it(
                    "do not raise_for_status and status is not 200", function()
                        local result, err = utils.parse_response(
                            {
                                body = '{"foo": "bar"}',
                                status = 500,
                            }, nil, false
                        )
                        assert.is_same(
                            result, {
                                foo = "bar",
                            }
                        )
                        assert.is_nil(err)
                    end
                )

                it(
                    "body is not json", function()
                        local result, err = utils.parse_response(
                            {
                                body = "not valid json",
                                status = 200,
                            }, true
                        )
                        assert.is_nil(result)
                        assert.is_equal(err, "response is not valid json")
                    end
                )

                it(
                    "ok", function()
                        local result, err = utils.parse_response(
                            {
                                body = '{"foo": "bar"}',
                                status = 200,
                            }, true
                        )
                        assert.is_same(
                            result, {
                                foo = "bar",
                            }
                        )
                        assert.is_nil(err)
                    end
                )
            end
        )
    end
)
