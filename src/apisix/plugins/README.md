# 插件

### 插件分类

- apisix 官方插件
- 蓝鲸官方 lua 插件

### 蓝鲸插件优先级

插件优先级说明

- 参考 apisix 官方插件优先级，蓝鲸插件优先级范围推荐：17000 ~ 19000
- 插件 ext-plugin-pre-req 中可能执行用户自定义 external plugin，因此蓝鲸官方的认证，校验逻辑插件优先级需高于此插件
- 插件 bk-permission 优先级需高于 ext-plugin-pre-req
- 上下文注入、认证阶段不能终结请求

插件优先级设置

上下文注入，优先级：18000 ~ 19000

- bk-opentelemetry                          # priority: 18870  # 这个插件用于 opentelemetry, 需要尽量精准统计全局的耗时, 同时需要注入trace_id/span_id作为后面所有插件自定义opentelemetry上报的trace_id即parent span_id
- bk-not-found-handler                      # priority: 18860  # 该插件仅适用于由 operator 创建的默认根路由，用以规范化 404 消息。该插件以较高优先级结束请求返回 404 错误信息
- bk-request-id                             # priority: 18850
- bk-stage-context                          # priority: 18840
- bk-service-context                        # priority: 18830
- bk-resource-context                       # priority: 18820
- bk-status-rewrite                         # priority: 18815
- bk-verified-user-exempted-apps            # priority: 18810
- bk-real-ip                                # priority: 18809
- bk-log-context                            # priority: 18800 # 该插件应默认应用于所有路由。该插件需要以较高优先级运行于请求响应及log阶段，目的在于：1. 在body_filter阶段获取后端返回的纯净body；2. 在log阶段为log插件注入相应日志变量

认证：

- bk-workflow-parameters                    # priority: 18750
- bk-auth-parameters                        # priority: 18740
- bk-auth-verify                            # priority: 18730

执行 - 响应: 优先级: 17500 ~ 18000

执行 - 请求

- bk-cors                                   # priority: 17900
- bk-break-recursive-call                   # priority: 17700  # 该插件应默认应用于所有路由
- bk-body-limit                             # priority: 17690
- bk-auth-validate                          # priority: 17680
- bk-jwt                                    # priority: 17670
- bk-ip-restriction                         # priority: 17662
- bk-ip-group-restriction                   # priority: 17661
- bk-concurrency-limit                      # priority: 17660
- bk-resource-rate-limit                    # priority: 17653
- bk-stage-rate-limit                       # priority: 17652
- bk-global-rate-limit                      # priority: 17651
- bk-permission                             # priority: 17640

proxy 预处理：17000 ~ 17500

- bk-delete-sensitive                       # priority: 17450
- bk-delete-cookie                          # priority: 17440
- bk-proxy-rewrite                          # priority: 17430 # 该插件供 operator 进行后端地址转换使用
- bk-stage-header-rewrite                   # priority: 17420
- bk-resource-header-rewrite                # priority: 17410
- bk-mock                                   # priority: 17150

响应后处理:

- bk-response-check                 # priority: 153
- bk-time-cost                      # priority: 150
- bk-debug                          # priority: 145
- bk-error-wrapper                  # priority: 0 # 该插件应默认应用于所有路由

默认：优先级：

- prometheus                        # priority: 500
- file-logger (priority update)     # priority: 399

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

官方插件需要向客户端返回的错误通过bk-core.errorx包来进行错误包装和返回。尽量使用已封装的错误进行错误处理，若已封装的错误不满足可以在errorx内添加新的错误类型。

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
--- err 应为通过errorx生成的error对象，否则会以500报错
--- _M 传入插件本身，用以获取插件的名称
return errorx.exit_with_apigw_err(ctx, err, _M)
