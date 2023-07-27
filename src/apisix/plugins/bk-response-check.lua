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
local exporter = require("apisix.plugins.prometheus.exporter")

---@type prometheus.Registry
local prometheus_registry

---@type prometheus.Counter
local metric_api_requests_total
---@type prometheus.Counter
local metric_app_requests_total

---@type prometheus.Histogram
local metric_api_request_duration

local schema = {}

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 153,
    name = "bk-response-check",
    schema = schema,
}

-- Initializes and registers the plugin metrics.
local function init_metrics()
    metric_api_requests_total = prometheus_registry:counter(
        "apigateway_api_requests_total",
        "How many HTTP requests processed, partitioned by status code, method and HTTP path.", {
            "gateway",
            "api_name",
            "stage_name",
            "resource_name",
            "service_name",
            "method",
            "matched_uri",
            "status",
            "proxy_phase",
            "proxy_error",
        }
    )

    metric_api_request_duration = prometheus_registry:histogram(
        "apigateway_api_request_duration_milliseconds",
        "How long it took to process the request, partitioned by status code, method and HTTP path.", {
            "gateway",
            "api_name",
            "stage_name",
            "resource_name",
            "service_name",
            "method",
            "matched_uri",
        }, {
            100,
            300,
            1000,
            5000,
        }
    )

    metric_app_requests_total = prometheus_registry:counter(
        "apigateway_app_requests_total", "How many HTTP requests per app_code/api/resource.", {
            "gateway",
            "app_code",
            "api_name",
            "stage_name",
            "resource_name",
            "service_name",
        }
    )
end



-- Initializes the plugin and its metrics.
function _M.init()
    prometheus_registry = exporter.get_prometheus()
    init_metrics()
end

---@param conf any
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

---@param conf any
---@param ctx apisix.Context
function _M.log(conf, ctx)
    local api_name = ctx.var.bk_gateway_name or ""
    local stage_name = ctx.var.bk_stage_name or ""
    local resource_name = ctx.var.bk_resource_name or ""
    local service_name = ctx.var.bk_service_name or ""
    local instance = ctx.var.instance_id or ""
    local method = ctx.var.method
    local proxy_phase = ctx.var.proxy_phase or ""
    local status = ctx.var.status
    local proxy_error = ctx.var.proxy_error or "0"

    -- NOTE: change from path to matched_uri, to decrease the metrics(use /a/{id} instead of /a/123)
    -- local path = ctx.var.uri
    local matched_uri = ""
    if ctx.curr_req_matched then
        matched_uri = ctx.curr_req_matched._path or ""
    end

    local status_label = ""
    if status then
        status_label = tostring(status)
    end

    metric_api_requests_total:inc(
        1, {
            instance,
            api_name,
            stage_name,
            resource_name,
            service_name,
            method,
            matched_uri,
            status_label,
            proxy_phase,
            proxy_error,
        }
    )

    if ctx.var.request_time then
        metric_api_request_duration:observe(
            ctx.var.request_time * 1000, {
                instance,
                api_name,
                stage_name,
                resource_name,
                service_name,
                method,
                matched_uri,
            }
        )
    end

    if ctx.var.bk_app_code then
        metric_app_requests_total:inc(
            1, {
                instance,
                ctx.var.bk_app_code,
                api_name,
                stage_name,
                resource_name,
                service_name,
            }
        )
    end
end

return _M
