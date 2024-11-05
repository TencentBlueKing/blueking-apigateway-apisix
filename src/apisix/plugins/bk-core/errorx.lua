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

local cjson = require("cjson")
local core = require("apisix.core")
local pl_types = require("pl.types")
local cjson_null = cjson.null
local ngx = ngx -- luacheck: ignore
local table_insert = table.insert
local table_concat = table.concat
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring

local _M = {}

-- exit a plugin
---@param ctx apisix.Context
---@param status any status code
---@param content string|nil response content
---@param skip_error_wrapper boolean|nil skip error wrapper
---@return integer|nil
---@return string|nil
function _M.exit_plugin(ctx, status, content, skip_error_wrapper)
    if not status then
        return
    end

    if ctx.var.bk_status_rewrite_200 then
        status = ngx.HTTP_OK
    end

    ngx.status = status
    ctx.var.bk_skip_error_wrapper = skip_error_wrapper

    return status, content
end

---bk plugins should call this function to exit with apigateway error
---@param ctx apisix.Context|nil apisix ctx
---@param apigwerr table|nil errorx generated error metatable
---@param plugin apisix.Plugin|nil plugin object, or table that has name field
---@return integer|nil status status code
---@return string|nil error_msg error message, empty message to avoid openresty default message
function _M.exit_with_apigw_err(ctx, apigwerr, plugin)
    if not ctx or not ctx.var then
        core.log.error("ctx and ctx.var can not be nil")
        return 500, ""
    end

    if not apigwerr then
        core.log.error("apigwerr can not be nil")
        return 500, ""
    end

    local plugin_name = plugin and plugin.name or "unknown"
    if apigwerr.status >= 500 then
        core.log.error(
            "plugin exited with error. ", "plugin_name: ", plugin_name, ", error: ",
            core.json.delay_encode(apigwerr, true)
        )
    end

    ctx.var.bk_apigw_error = apigwerr

    return _M.exit_plugin(ctx, apigwerr.status, "", false)
end

local apigw_error = {}

function apigw_error:with_field(key, value)
    local fields = {}
    fields[key] = value
    self:with_fields(fields)
    return self
end

function apigw_error:with_fields(fields)
    if type(fields) ~= "table" then
        core.log.error("fields should be a table: ", core.json.delay_encode(fields))
        return self
    end

    if pl_types.is_empty(fields) then
        return self
    end

    local key_value_pairs = {}
    for key, value in pairs(fields) do
        table_insert(key_value_pairs, tostring(key) .. '="' .. tostring(value) .. '"')
    end
    local params = table_concat(key_value_pairs, " ")

    if pl_types.is_empty(self.error.message) then
        self.error.message = params
    else
        self.error.message = self.error.message .. " [" .. params .. "]"
    end

    return self
end

local mt = {
    __index = apigw_error,
    __tostring = function(self)
        return core.json.encode(self, true)
    end,
}

-- defined error generators begin

function _M.new_internal_server_error()
    local error = {
        error = {
            code = 1650001,
            code_name = "INTERNAL_SERVER_ERROR",
            message = "Internal Server Error",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_INTERNAL_SERVER_ERROR,
    }
    return setmetatable(error, mt)
end

function _M.new_general_unauthorized()
    local error = {
        error = {
            code = 1640100,
            code_name = "UNAUTHORIZED",
            message = "Unauthorized",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_UNAUTHORIZED,
    }
    return setmetatable(error, mt)
end

function _M.new_app_verify_failed()
    local error = {
        error = {
            code = 1640101,
            code_name = "APP_VERIFY_FAILED",
            message = "App authentication failed",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_UNAUTHORIZED,
    }
    return setmetatable(error, mt)
end

function _M.new_user_verify_failed()
    local error = {
        error = {
            code = 1640102,
            code_name = "USER_VERIFY_FAILED",
            message = "User authentication failed",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_UNAUTHORIZED,
    }
    return setmetatable(error, mt)
end

function _M.new_app_no_permission()
    local error = {
        error = {
            code = 1640301,
            code_name = "APP_NO_PERMISSION",
            message = "App has no permission to the resource",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_FORBIDDEN,
    }
    return setmetatable(error, mt)
end

function _M.new_invalid_args()
    local error = {
        error = {
            code = 1640001,
            code_name = "INVALID_ARGS",
            message = "Parameters error",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_BAD_REQUEST,
    }
    return setmetatable(error, mt)
end

function _M.new_jwt_verify_failed()
    local error = {
        error = {
            code = 1640004,
            code_name = "JWT_VERIFY_FAILED",
            message = "JWT validation failed",
            result = false,
            data = cjson_null,
        },
        status = ngx.HTTP_BAD_REQUEST,
    }
    return setmetatable(error, mt)
end

function _M.new_recursive_request_detected()
    local error = {
        error = {
            code = 1650801,
            code_name = "RECURSIVE_REQUEST_DETECTED",
            message = "Recursive request detected, please contact the api manager to check the resource configuration",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 508,
    }
    return setmetatable(error, mt)
end

function _M.new_ip_not_allowed()
    local error = {
        error = {
            code = 1640302,
            code_name = "IP_NOT_ALLOWED",
            message = "Request rejected by ip restriction",
            result = false,
            data = cjson_null,
        },
        status = 403,
    }
    return setmetatable(error, mt)
end

function _M.new_bk_user_not_allowed()
    local error = {
        error = {
            code = 1640303,
            code_name = "BK_USER_NOT_ALLOWED",
            message = "Request rejected by bk-user restriction",
            result = false,
            data = cjson_null,
        },
        status = 403,
    }
    return setmetatable(error, mt)
end

function _M.new_request_body_size_exceed()
    local error = {
        error = {
            code = 1641301,
            code_name = "BODY_SIZE_LIMIT_EXCEED",
            message = "Request body size too large.",
            result = false,
            data = cjson_null,
        },
        status = 413,
    }
    return setmetatable(error, mt)
end

function _M.new_request_uri_size_exceed()
    local error = {
        error = {
            code = 1641401,
            code_name = "URI_SIZE_LIMIT_EXCEED",
            message = "Request uri size too large.",
            result = false,
            data = cjson_null,
        },
        status = 414,
    }
    return setmetatable(error, mt)
end

function _M.new_concurrency_limit_restriction()
    local error = {
        error = {
            code = 1642904,
            code_name = "CONCURRENCY_LIMIT_RESTRICTION",
            message = "Request concurrency exceeds",
            result = false,
            data = cjson_null,
        },
        status = 429,
    }
    return setmetatable(error, mt)
end

function _M.new_stage_global_rate_limit_restriction()
    local error = {
        error = {
            code = 1642901,
            code_name = "RATE_LIMIT_RESTRICTION",
            message = "API rate limit exceeded by stage global limit",
            result = false,
            data = cjson_null,
        },
        status = 429,
    }
    return setmetatable(error, mt)
end

function _M.new_stage_strategy_rate_limit_restriction()
    local error = {
        error = {
            code = 1642902,
            code_name = "RATE_LIMIT_RESTRICTION",
            message = "API rate limit exceeded by stage strategy",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 429,
    }
    return setmetatable(error, mt)
end

function _M.new_resource_strategy_rate_limit_restriction()
    local error = {
        error = {
            code = 1642903,
            code_name = "RATE_LIMIT_RESTRICTION",
            message = "API rate limit exceeded by resource strategy",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 429,
    }
    return setmetatable(error, mt)
end

function _M.new_error_requesting_resource()
    local error = {
        error = {
            code = 1650201,
            code_name = "ERROR_REQUESTING_RESOURCE",
            message = "Request backend service failed",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 502,
    }
    return setmetatable(error, mt)
end

function _M.new_request_backend_timeout()
    local error = {
        error = {
            code = 1650401,
            code_name = "REQUEST_BACKEND_TIMEOUT",
            message = "Request backend service timeout",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 504,
    }
    return setmetatable(error, mt)
end

function _M.new_request_resource_5xx()
    local error = {
        error = {
            code = 1650000,
            code_name = "REQUEST_RESOURCE_5xx",
            message = "Request backend service status code is 5xx",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 500,
    }
    return setmetatable(error, mt)
end

function _M.new_invalid_resource_config()
    local error = {
        error = {
            code = 1650002,
            code_name = "INVALID_RESOURCE_CONFIG",
            message = "Resource configuration error",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 500,
    }
    return setmetatable(error, mt)
end

function _M.new_api_not_found()
    local error = {
        error = {
            code = 1640401,
            code_name = "API_NOT_FOUND",
            message = "API not found",
            result = false,
            data = cjson_null,
        },
        -- StatusLoopDetected
        status = 404,
    }
    return setmetatable(error, mt)
end

function _M.new_bad_gateway()
    local error = {
        error = {
            code = 1650200,
            code_name = "BAD_GATEWAY",
            message = "Bad Gateway",
            result = false,
            data = cjson_null,
        },
        status = 502,
    }
    return setmetatable(error, mt)
end

function _M.new_service_unavailable()
    local error = {
        error = {
            code = 1650300,
            code_name = "SERVICE_UNAVAILABLE",
            message = "Service Unavailable",
            result = false,
            data = cjson_null,
        },
        status = 503,
    }
    return setmetatable(error, mt)
end

---@param status_code integer
function _M.new_unkonwon_error(status_code)
    if type(status_code) ~= "number" then
        status_code = ngx.HTTP_INTERNAL_SERVER_ERROR
        core.log.warn("status_code is not number, status_code: ", tostring(status_code))
    end

    local error = {
        error = {
            code = 1650070,
            code_name = "UNKNOWN_ERROR",
            message = "unknown error",
            result = false,
            data = cjson_null,
        },
        status = status_code,
    }
    return setmetatable(error, mt)
end

-- status default error factory
local status_error_factory = {
    [ngx.HTTP_UNAUTHORIZED] = _M.new_general_unauthorized,
    [ngx.HTTP_BAD_REQUEST] = _M.new_invalid_args,
    [ngx.HTTP_NOT_FOUND] = _M.new_api_not_found,
    [413] = _M.new_request_body_size_exceed,
    [414] = _M.new_request_uri_size_exceed,
    [ngx.HTTP_INTERNAL_SERVER_ERROR] = _M.new_internal_server_error,
    [ngx.HTTP_BAD_GATEWAY] = _M.new_bad_gateway,
    [ngx.HTTP_SERVICE_UNAVAILABLE] = _M.new_service_unavailable,
    [ngx.HTTP_GATEWAY_TIMEOUT] = _M.new_request_backend_timeout,
}

function _M.new_default_error_with_status(status_code)
    local handler = status_error_factory[status_code]
    if not handler then
        core.log.warn("status_code is unexpected, status_code: ", tostring(status_code))
        return _M.new_unkonwon_error(status_code)
    end

    return handler()
end

if _TEST then -- luacheck: ignore
    _M._mt = mt
    _M._status_error_factory = status_error_factory
end

return _M
