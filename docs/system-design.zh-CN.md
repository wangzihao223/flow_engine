# Flow Engine 系统设计

## 1. 目标

Flow Engine 是一个使用 Elixir/OTP 实现的节点流运行时，负责工作流编排、消息路由、节点生命周期和故障恢复。

系统保持现有 Python 前端使用的 workflow JSON、节点消息和连接格式，逐步替换 Python 工作流引擎。相机采集、视觉处理和模型推理由独立服务负责，Flow Engine 只处理流控制和业务结果。

## 2. 系统边界

```text
浏览器前端
    │ REST / SSE / WebSocket
    ▼
Elixir API 兼容层
    │
    ▼
Flow Engine
    ├── 普通节点进程
    ├── 设备节点进程
    ├── Python 服务适配器
    ├── hik 相机服务适配器
    └── 工作流持久化与运行态恢复

相机 Erlang 服务 ── iceoryx ── Python 视觉/推理服务
```

Flow Engine 不负责：

- 海康 SDK 的设备控制；
- 相机底层采集和图像编码；
- OpenCV、Torch 或 YOLO 的具体实现；
- 在 BEAM 内保存共享内存指针；
- 直接执行不受信任的任意代码。

## 3. 核心概念

### 3.1 节点流图

工作流是有向图，不要求无环。一个节点可以有多个输入端口和输出端口，连接可以形成循环。

消息通过 Erlang mailbox 异步传递，节点之间不使用同步递归调用，因此环路不会导致调用栈递归。

所有可能形成环路的工作流必须配置 `max_hops`。消息超过限制后丢弃并记录运行事件。

### 3.2 节点进程

每个运行中的节点对应一个 `GenServer`，节点内部串行处理自己的输入队列。

节点行为：

```elixir
@callback init(config :: map()) :: {:ok, state} | {:error, reason}

@callback handle_message(input_port, message, state) ::
  {:ok, state}
  | {:emit, [{output_port, message}], state}
  | {:error, reason, state}
```

节点不直接访问其他节点，也不直接修改工作流图。

### 3.3 工作流消息

业务消息保持现有 Node-RED 风格结构：

```elixir
%{
  "_msgid" => "...",
  "topic" => "camera/frame",
  "payload" => %{
    "image" => %{},
    "plc" => %{},
    "ai" => %{},
    "logic" => %{}
  }
}
```

`payload` 的合并和命名空间规则保持现有约定。内部 hop 计数、调度信息和监控数据不写入业务消息。

## 4. 监督树

目标监督树：

```text
FlowEngine.Application
└── FlowSupervisor
    ├── WorkflowSupervisor
    │   ├── WorkflowRuntime
    │   ├── NodeSupervisor
    │   │   ├── NodeServer: node-a
    │   │   ├── NodeServer: node-b
    │   │   └── ...
    │   └── CheckpointWorker
    ├── PythonGatewaySupervisor
    └── AdapterSupervisor
```

节点采用 `one_for_one`：单个节点崩溃只重启该节点。节点重启后必须重新向工作流注册 PID，并根据工作流状态恢复运行或保持停止。

设备适配器和 Python gateway 也必须单独受监督，不能因为一个外部服务失败而重启整个工作流。

## 5. 节点生命周期

节点状态包括：

```text
created → stopped → starting → running
                         │       │
                         │       └── stopping → stopped
                         └── failed → backoff → starting
```

要求：

- 工作流启动后，所有节点按统一顺序进入 `running`；
- 节点初始化失败时记录错误，不阻塞其他节点启动；
- 节点崩溃后按退避策略重启；
- 工作流停止时先停止输入源，再停止处理节点，最后停止输出节点；
- 停止和重启必须释放定时器、socket、Port、订阅句柄和共享内存 sample；
- 节点重启不默认恢复临时图片和外部连接对象。

## 6. 消息队列与背压

每个节点使用有界队列，避免慢节点无限占用内存。

配置项：

```text
max_queue
drop_policy       drop_newest | drop_oldest | reject
processing_timeout
max_hops
```

默认行为建议：

- 普通业务节点：`drop_newest` 或报告错误；
- 相机实时帧：`drop_oldest`，只保留较新的帧；
- PLC 控制命令：`reject`，不能静默丢弃；
- Python 推理请求：限制并发，超时后返回明确错误；
- 所有丢弃、超时和拒绝都产生结构化运行事件。

## 7. 相机和图片传递

`hik` 项目继续作为独立相机服务，不并入 Flow Engine。

### 7.1 推荐数据路径

```text
Hikvision SDK
    ↓
iceoryx raw / JPEG topic
    ├── Elixir 相机适配器：控制和元数据
    └── Python 视觉服务：直接订阅图片
```

Flow Engine 消息只携带图片描述：

```elixir
%{
  "frame_id" => %{
    "camera_id" => "CAM-01",
    "generation" => 12,
    "sequence" => 83921
  },
  "format" => "raw",
  "width" => 1920,
  "height" => 1080,
  "timestamp_ns" => 0
}
```

`camera_id + generation + sequence` 是稳定帧标识。`generation` 用于区分相机重连后的新会话。

### 7.2 BEAM binary 模式

需要在 Elixir 内部传递 JPEG 时，可以调用 NIF 的 `frame_binary/1`。大 binary 在 BEAM 进程之间通常共享底层数据，但从 iceoryx sample 到 BEAM binary 仍会发生一次复制。

NIF frame resource 不能作为普通工作流消息长期传递。读取后必须及时 `release`。

## 8. Python 视觉和推理服务

Python 服务通过独立 gateway 调用，不让节点直接阻塞等待外部服务。

请求包含：

```text
request_id
frame_id
node_id
workflow_id
operation
deadline
```

响应包含：

```text
request_id
frame_id
status
result
processing_time_ms
error
```

适配器负责：

- 请求并发限制；
- 超时；
- 重试；
- request_id 关联；
- 服务断开后的重连；
- 结果幂等；
- 监控处理延迟。

视觉服务优先直接订阅 iceoryx，避免图片先复制到 BEAM 再传给 Python。

## 9. PLC 节点

一个 PLC 连接对应一个受监督的设备 actor。所有读写命令经过该 actor 串行化。

PLC 节点负责业务流路由，PLC adapter 负责：

- 连接和重连；
- 请求超时；
- 有限重试；
- 读回确认；
- 写操作幂等键；
- 危险动作恢复后的人工确认。

## 10. 前端兼容

保持现有 workflow JSON：

```json
{
  "nodes": [],
  "connections": []
}
```

节点字段保留：

- `id`；
- `type`；
- `name`；
- `config`；
- `x`；
- `y`。

连接字段保留：

- `source`；
- `target`；
- `sourceOutput`；
- `targetInput`。

兼容层负责把 JSON 节点类型解析为 Elixir 模块。前端不需要知道节点是否由 Elixir、Python 或外部 Erlang 服务实现。

## 11. 节点类型注册

注册表将前端类型名称映射到 Elixir 模块：

```elixir
registry =
  FlowEngine.NodeRegistry.new()
  |> FlowEngine.NodeRegistry.register!("SwitchNode", SwitchNode)
  |> FlowEngine.NodeRegistry.register!("DelayNode", DelayNode)
```

未知节点类型在加载阶段报告错误，不创建半初始化节点。

## 12. 持久化和恢复

需要区分两类数据：

### 工作流定义

- 节点类型；
- 节点配置；
- 节点布局；
- 连接；
- 版本号。

### 运行态

- 节点业务状态；
- 计数器；
- 去抖状态；
- cycle_id；
- 最近 checkpoint 时间。

不保存：

- 共享内存地址；
- NIF resource；
- socket、Port 和连接句柄；
- 未确认的危险动作；
- Python 进程对象。

保存方式：

1. 写入临时文件；
2. `fsync`；
3. 保留 `.bak`；
4. 原子替换目标文件；
5. 校验 revision 和 workflow hash。

## 13. API 和事件

在项目目录运行 `mix run start.exs` 即可启动旧前端和工作流引擎。默认端口为 `4000`，工作流保存在 `data/workflow.json`；可通过 `FLOW_ENGINE_PORT` 和 `FLOW_ENGINE_WORKFLOW_FILE` 环境变量修改。使用 `Ctrl+C` 停止服务。

当前可以直接启动单工作流 HTTP 服务：

```elixir
{:ok, engine} = FlowEngine.start_link()
{:ok, _server} = FlowEngine.HttpServer.start_link(engine: engine, port: 4000)
```

HTTP 服务使用 Elixir 的 Plug 和 Bandit，默认监听本机 `4000` 端口。

旧 Python 前端已迁移到 `priv/static/`，入口为 `index.html`，原有 `js/`、`style.css`、`images/` 和 `examples/` 相对路径保持不变。Bandit 直接托管这些资源，浏览器无需修改静态资源地址。

当前 HTTP 兼容层（Plug + Bandit）已经提供以下单工作流接口：

```text
GET    /health/live
GET    /health/ready
GET    /api/health
GET    /api/workflows
GET    /api/workflow
GET    /api/workflow/deployed
POST   /api/workflow
POST   /api/workflow/start
POST   /api/workflow/stop
POST   /api/messages
GET    /api/nodes
GET    /api/node-types
GET    /api/events
GET    /api/events/stream
GET    /api/debug/stream
POST   /api/workflow/save
GET    /api/nodes/:id
POST   /api/nodes
PUT    /api/nodes/:id
DELETE /api/nodes/:id
POST   /api/connections
DELETE /api/connections
```

工作流导入和导出继续使用现有 `nodes` / `connections` JSON 字段，业务消息保持原有结构。接口错误统一返回 JSON，工作流导入失败或消息目标不存在时返回 `400`，未知路径返回 `404`。

当前编辑器的“部署”和“完整部署”都提交完整工作流到 `POST /api/workflow/save?workflow=:id`。服务端先校验并替换对应工作流的运行定义，再写入工作流文件；失败时恢复原有运行定义，成功后启动已启用的工作流。`POST /api/workflow/deploy-changes` 暂不提供增量部署，调用时返回错误，避免误报部署成功。

多工作流管理已支持创建、重命名、启停、切换和删除。每个工作流使用独立引擎，工作流列表和定义统一保存在 `FLOW_ENGINE_WORKFLOW_FILE` 指向的 JSON 文件中；启动时也能读取旧版单工作流文件。切换编辑器标签只更改当前编辑对象，已启用的其他工作流继续运行。`/api/events/stream?workflow=:id` 和 `/api/debug/stream?workflow=:id` 提供持续 SSE 推送、15 秒心跳和断开清理；运行事件支持 `Last-Event-ID` 续传。已实现的管理接口包括：

```text
GET    /api/workflows
POST   /api/workflows
PUT    /api/workflows/:id
DELETE /api/workflows/:id
POST   /api/workflows/:id/start
POST   /api/workflows/:id/stop
GET    /api/node-types
```

运行事件统一包含：

```json
{
  "workflowId": "...",
  "nodeId": "...",
  "type": "queue_full",
  "timestamp": 0,
  "details": {}
}
```

### 设备节点配置

`CameraNode` 使用 hik 服务的 `/api/v1/cameras/:serial` 状态查询和 `/triggers/software` 软件触发接口，配置 `serial`、`base_url`、`action`、`timeout_ms`、`token`。输出附带 `HikCamera/<serial>/Raw` topic 描述。触发响应只表示命令已接受，不代表帧已到达，也不生成虚假的 `frame_id`；Python 服务须先订阅 iceoryx topic 再处理触发后的图片。

`VisionNode` 与 `InferenceNode` 配置 `url`、`operation`、`timeout_ms`、`token`。输入消息需包含 `frame_id` 或 `topic`；HTTP 请求只发送这些帧引用及 `request_id`、截止时间，不发送图片字节。服务响应需包含同一个 `request_id`、`status: "ok"` 和 `result`。Python 服务具体路由由部署者提供。

`PLCNode` 在编辑器里分别配置操作、PLC 服务地址、设备 ID、可选访问令牌、DB 编号、偏移、数据类型和超时。布尔点位显示位号（0–7）；字符串和字节数组显示长度。无需手写连接或点位 JSON。启动脚本默认使用 `FlowEngine.Adapters.PLCServerHTTP` 对接独立的 `plc_server`；嵌入式启动时可通过 `Application.put_env(:flow_engine, :plc_transport, 模块)` 注入其他传输。旧工作流中的 `connection` 对象和 `address` 字符串仍可运行；编辑器会将可识别的旧版点位 JSON 转换成表单字段。写入消息需有 `request_id` 和 `value`。适配器不自动重试写入；当前 `plc_server` 不按 `request_id` 去重，网络超时后写入结果可能不确定，需要由上层确认，不能自动重发。

## 14. 安全边界

- 不在 Flow Engine 内直接执行不受信任的 Elixir 或 Python 代码；
- Python 服务运行在独立进程和明确权限下；
- API 保留 API key 或等效认证机制；
- 上传文件使用独立目录和大小限制；
- 节点配置校验不能只依赖前端；
- 外部服务地址、凭据和模型路径不写入运行态快照。

## 15. 实施阶段

### 阶段一：运行时基础

- 节点行为协议；
- 有界队列；
- 环路和 `max_hops`；
- 节点类型注册；
- workflow JSON 导入导出。

### 阶段二：内置节点

- Inject；
- Change；
- Switch；
- Delay；
- Debug；
- Counter；
- Join / Split。

### 阶段三：外部服务

- hik 相机适配器；
- Python 视觉服务；
- Python 推理服务；
- PLC 适配器。

### 阶段四：平台兼容

- REST API；
- SSE/WebSocket；
- 前端节点类型接口；
- workflow 保存和恢复；
- 运行态 checkpoint。

### 阶段五：灰度替换

1. 使用同一份 workflow JSON 在 Python 和 Elixir 中加载；
2. Elixir 运行 shadow 模式，只记录结果；
3. 对比消息、延迟、丢弃和设备行为；
4. 先切换纯逻辑节点；
5. 再切换设备和外部服务节点；
6. 保留 Python 引擎作为回退路径。

## 16. 当前原型状态

已经实现：

- Elixir 节点行为；
- 节点 GenServer；
- DynamicSupervisor；
- 节点流路由；
- 环路；
- hop 限制；
- 有界队列；
- workflow JSON 加载；
- workflow JSON 导出；
- 节点类型注册表。
- `PassThroughNode`、`ChangeNode`、`SwitchNode`、`CounterNode`。
- 运行事件缓存和 `FlowEngine.events/1` 查询。
- 基于 Plug + Bandit 的 Elixir HTTP 路由。
- HTTP workflow 持久化路径和 `.bak` 恢复。
- SSE 实时事件推送及旧前端 `/api/debug/stream` 兼容接口。
- 运行态 checkpoint 保存与恢复。
- 旧前端静态资源迁移和 `/api` 关键调用兼容。
- hik HTTP 控制、Python 元数据请求以及 plc_server HTTP 点位读写适配器。

尚未实现：

- 节点崩溃后的完整运行状态自动恢复；
- `InjectNode`、`DelayNode`、`DebugNode`、`JoinNode`、`SplitNode`；
- iceoryx 帧引用生产者、Python 服务的正式协议和 PLC 写入的服务端幂等处理；
- WebSocket 兼容层；
- 生产级监控和持久化。
