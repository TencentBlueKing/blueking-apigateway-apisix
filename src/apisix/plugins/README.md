# 插件

## 插件分类

- apisix 官方插件
- 蓝鲸官方 lua 插件

## 蓝鲸插件优先级

插件优先级说明

- 参考 apisix 官方插件优先级，蓝鲸插件优先级范围推荐：17000 ~ 19000
- 已经去除 external plugin
  - ~~插件 ext-plugin-pre-req 中可能执行用户自定义 external plugin，因此蓝鲸官方的认证，校验逻辑插件优先级需高于此插件~~
  - ~~插件 bk-permission 优先级需高于 ext-plugin-pre-req~~
- 上下文注入、认证阶段不能终结请求

插件优先级设置

上下文注入，优先级：18000 ~ 19000

- bk-legacy-invalid-params                  # priority: 18880  # 用于兼容老版本 go1.16 使用 `;` 作为 query string 分隔符
- ~~bk-opentelemetry                          # priority: 18870  # 这个插件用于 opentelemetry, 需要尽量精准统计全局的耗时，同时需要注入 trace_id/span_id 作为后面所有插件自定义 opentelemetry 上报的 trace_id 即 parent span_id (abandonned, will be replaced by another plugin)~~
- bk-not-found-handler                      # priority: 18860  # 该插件仅适用于由 operator 创建的默认根路由，用以规范化 404 消息。该插件以较高优先级结束请求返回 404 错误信息
- bk-request-id                             # priority: 18850
- bk-stage-context                          # priority: 18840
- ~~bk-service-context                        # priority: 18830 (abandonned)~~
- bk-backend-context                        # priority: 18825
- bk-resource-context                       # priority: 18820
- bk-status-rewrite                         # priority: 18815 (will be deprecated)
- bk-verified-user-exempted-apps            # priority: 18810 (will be deprecated)
- bk-real-ip                                # priority: 18809
- bk-log-context                            # priority: 18800 # 该插件应默认应用于所有路由。该插件需要以较高优先级运行于请求响应及 log 阶段，目的在于：1. 在 body_filter 阶段获取后端返回的纯净 body；2. 在 log 阶段为 log 插件注入相应日志变量

CORS（上下文初始化之后，认证之前）：

- bk-cors                                   # priority: 18750  # 预检直接返回，并为认证错误响应保存 Origin

请求体限额（CORS 之后，所有认证之前）：

- bk-request-body-limit                     # priority: 18745  # 在认证读取请求体之前设置限额

认证：

- ~~bk-workflow-parameters                    # priority: 18750 (abandonned)~~
- ~~bk-auth-parameters                        # priority: 18740 (abandonned)~~
- bk-oauth2-protected-resource              # priority: 18740  # OAuth2 资源保护：检测 OAuth2 vs 传统认证，返回 WWW-Authenticate 头
- bk-access-token-source                    # priority: 18735
- bk-oauth2-verify                          # priority: 18732  # OAuth2 令牌验证：通过 bkauth 验证 OAuth2 访问令牌
- bk-auth-verify                            # priority: 18730
- bk-username-required                      # priority: 18725

执行 - 响应：优先级：17500 ~ 18000

执行 - 请求

- bk-break-recursive-call                   # priority: 17700  # 该插件应默认应用于所有路由
- bk-auth-validate                          # priority: 17680
- bk-user-restriction                       # priority: 17679
- bk-oauth2-appcode-validate                # priority: 17678  # OAuth2 app code 验证：按路由配置允许 public 和 personal 客户端
- bk-oauth2-audience-validate               # priority: 17677  # OAuth2 audience 验证：验证 MCP 服务器和网关 API 的 audience 声明
- bk-tenant-validate-exempt                 # priority: 17676  # 如果资源配置了此插件, 则跳过 bk-tenant-validate 校验
- bk-tenant-verify                          # priority: 17675
- bk-tenant-validate                        # priority: 17674
- bk-tenant-restriction                     # priority: 17673
- bk-jwt                                    # priority: 17670
- bk-ip-restriction                         # priority: 17662
- ~~bk-ip-group-restriction                   # priority: 17661 (1.18 removed)~~
- bk-concurrency-limit                      # priority: 17660 (disabled by default, should fix the bug of bk-concurrency-limit)
- bk-resource-user-rate-limit               # priority: 17654  # 按 bk_username 的资源限流
- bk-resource-rate-limit                    # priority: 17653
- bk-stage-rate-limit                       # priority: 17652
- ~~bk-global-rate-limit                      # priority: 17651 (1.18 removed)~~
- bk-stage-global-rate-limit                # priority: 17651 (not used, but just keep in codebase, maybe will be used in the future)
- bk-permission                             # priority: 17640

proxy 预处理：17000 ~ 17500

- bk-traffic-label                          # priority: 17460
- bk-delete-sensitive                       # priority: 17450
- bk-delete-cookie                          # priority: 17440
- bk-query-string-rewrite                   # priority: 17435
- bk-proxy-rewrite                          # priority: 17430 # 该插件供 operator 进行后端地址转换使用
- bk-default-tenant                         # priority: 17425
- bk-stage-header-rewrite                   # priority: 17421
- bk-resource-header-rewrite                # priority: 17420
- bk-mock                                   # priority: 17150

官方插件：

- fault-injection                           # priority: 11000
- request-validation                        # priority: 2800
- api-breaker                               # priority: 1005
- redirect                                  # priority: 900
- response-rewrite                          # priority: 899
- prometheus                                # priority: 500
- file-logger (priority update)             # priority: 399

响应后处理：

- bk-response-check                         # priority: 153
- ~~bk-time-cost                              # priority: 150 (not implemented)~~
- bk-debug                                  # priority: 145
- bk-error-wrapper                          # priority: 0 # 该插件应默认应用于所有路由

## 按用户的资源限流

`bk-resource-user-rate-limit` 使用认证插件写入的 `ctx.var.bk_username`，
按「用户名 + 网关 + 环境 + 资源名」分别计数。同一用户通过不同应用访问同一资源时共享配额，
不同用户互不影响。没有用户名或用户名为空的请求跳过此插件。
它可以与按应用的 `bk-resource-rate-limit` 同时启用，两种配额分别计算。

配置格式与 `bk-resource-rate-limit` 类似，`rates` 的键改为用户名：

```json
{
  "bk-resource-user-rate-limit": {
    "rates": {
      "__default": [{"period": 60, "tokens": 100}],
      "alice": [{"period": 1, "tokens": 10}, {"period": 60, "tokens": 300}],
      "bob": []
    },
    "allow_degradation": true,
    "show_limit_quota_header": true
  }
}
```

- `__default` 是保留键，提供每个用户的默认配额；缺少 `rates` 或 `__default` 时跳过限流。
- 用户专属规则完全覆盖默认规则；空数组表示该用户不限流。默认规则也可为空数组。
- `period` 为正整数秒数，`tokens` 为该窗口允许的正整数请求数。配置多个窗口时，每个窗口都需满足。
- `allow_degradation` 默认为 `true`，Redis 异常时放行；设为 `false` 时拒绝请求，沿用资源限流错误。
- `show_limit_quota_header` 默认为 `true`，返回 `X-Bkapi-RateLimit-*` 配额响应头，
  其中 `X-Bkapi-RateLimit-Plugin` 标识当前设置响应头的插件。
- 复用 `plugin_attr.bk-rate-limit` 的 Redis 配置；超限返回 HTTP 429，错误码为 `1642903`。

## 插件开发

### 推荐插件

- https://marketplace.visualstudio.com/items?itemName=sumneko.lua
- https://marketplace.visualstudio.com/items?itemName=yinfei.luahelper
- https://marketplace.visualstudio.com/items?itemName=rog2.luacheck

### 代码补全

根目录执行 `make apisix-core`

### 错误处理与校验

对于有错误消息返回的函数，需要对错误消息进行判断和处理，错误消息要作为第二个参数，用字符串格式返回。判断时，优先判断数据是否有效，如果无效，返回错误消息。

```lua
-- No
local function foo()
    local result, err = func()
    if err ~= nil then
        return nil, {msg = err}
    end
    return result
end

-- Yes
local function foo()
    local result, err = func()
    if not result then
        return nil, "failed to call func(): " .. err
    end
    return result
end
```

## 插件错误处理

官方插件需要向客户端返回的错误通过 bk-core.errorx 包来进行错误包装和返回。尽量使用已封装的错误进行错误处理，若已封装的错误不满足可以在 errorx 内添加新的错误类型。

### 生成错误

#### 生成已有错误类型

```lua
local errorx = require("apisix.plugins.bk-core.errorx")

local err = errorx.new_user_verify_failed()
```

### 添加错误信息

```lua
err = err:with_field("key", "value")
err = err:with_fields(
    {
        key1 = "value1",
        key2 = "value2",
    }
)
```

### 以错误退出请求

```lua
--- err 应为通过 errorx 生成的 error 对象，否则会以 500 报错
--- _M 传入插件本身，用以获取插件的名称
return errorx.exit_with_apigw_err(ctx, err, _M)
