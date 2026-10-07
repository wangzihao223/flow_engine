defmodule FlowEngine.HttpRouter do
  @moduledoc "使用 Plug 实现的前端兼容 HTTP 路由。"

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    engine = Keyword.fetch!(opts, :engine)
    registry = Keyword.get(opts, :registry, FlowEngine.NodeRegistry.builtins())
    persistence_path = Keyword.get(opts, :persistence_path)

    static_conn = serve_static(conn)

    if static_conn.halted do
      static_conn
    else
      case Keyword.get(opts, :manager) do
        nil ->
          if conn.method == "POST" and conn.request_path == "/api/workflow/save" do
            save_workflow(conn, engine, registry, persistence_path)
          else
            dispatch(conn, conn.method, conn.request_path, engine, registry)
          end

        manager ->
          managed(conn, manager, registry)
      end
    end
  rescue
    error -> json(conn, 500, %{success: false, error: Exception.message(error)})
  end

  defp managed(conn, manager, registry) do
    conn = fetch_query_params(conn)
    requested_id = Map.get(conn.query_params, "workflow")

    case {conn.method, conn.request_path} do
      {"GET", "/api/workflows"} ->
        json(conn, 200, FlowEngine.WorkflowManager.list(manager))

      {"GET", "/api/workflows/active"} ->
        json(conn, 200, FlowEngine.WorkflowManager.active(manager))

      {"PUT", "/api/workflows/active"} ->
        managed_activate(conn, manager)

      {"POST", "/api/workflows"} ->
        managed_create(conn, manager)

      {"POST", "/api/workflow/save"} ->
        managed_deploy(conn, manager, requested_id, 200)

      {"POST", "/api/workflow"} ->
        managed_deploy(conn, manager, requested_id, 201)

      {"POST", "/api/workflow/start"} ->
        command(conn, FlowEngine.WorkflowManager.start_all(manager))

      {"POST", "/api/workflow/stop"} ->
        workflow_command(conn, FlowEngine.WorkflowManager.stop_all(manager), :stopped)

      {"POST", "/api/workflow/restart"} ->
        workflow_command(conn, FlowEngine.WorkflowManager.restart_all(manager), :restarted)

      {method, "/api/workflows/" <> rest} ->
        managed_workflow(conn, manager, method, rest)

      _ ->
        case FlowEngine.WorkflowManager.engine(manager, requested_id) do
          {:ok, engine} ->
            workflow_id = requested_id || FlowEngine.WorkflowManager.active(manager).id

            case {conn.method, conn.request_path} do
              {"GET", "/api/events/stream"} -> events_stream(conn, engine, workflow_id)
              {"GET", "/api/debug/stream"} -> debug_stream(conn, engine, workflow_id)
              _ -> dispatch(conn, conn.method, conn.request_path, engine, registry)
            end

          {:error, :not_found} ->
            json(conn, 404, %{success: false, error: "Workflow not found"})
        end
    end
  end

  defp managed_activate(conn, manager) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, id} <- fetch(data, "workflowId"),
         {:ok, workflow} <- FlowEngine.WorkflowManager.activate(manager, id) do
      json(conn, 200, %{success: true, activeWorkflow: workflow.id})
    else
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Workflow not found"})
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp managed_create(conn, manager) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, workflow} <-
           FlowEngine.WorkflowManager.create(manager, Map.get(data, "name", "New Workflow")) do
      json(conn, 201, workflow)
    else
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp managed_workflow(conn, manager, method, rest) do
    case {method, String.split(rest, "/", parts: 2)} do
      {"GET", [id]} ->
        case Enum.find(FlowEngine.WorkflowManager.list(manager), &(&1.id == id)) do
          nil -> json(conn, 404, %{success: false, error: "Workflow not found"})
          workflow -> json(conn, 200, workflow)
        end

      {"PUT", [id]} ->
        with {:ok, data, conn} <- read_json(conn),
             {:ok, workflow} <- FlowEngine.WorkflowManager.update(manager, id, data) do
          json(conn, 200, workflow)
        else
          {:error, :not_found} -> json(conn, 404, %{success: false, error: "Workflow not found"})
          {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
        end

      {"DELETE", [id]} ->
        case FlowEngine.WorkflowManager.delete(manager, id) do
          {:ok, active} -> json(conn, 200, %{success: true, activeWorkflow: active})
          {:error, :not_found} -> json(conn, 404, %{success: false, error: "Workflow not found"})
          {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
        end

      {"POST", [id, "start"]} ->
        command(conn, FlowEngine.WorkflowManager.start(manager, id))

      {"POST", [id, "stop"]} ->
        command(conn, FlowEngine.WorkflowManager.stop(manager, id))

      _ ->
        json(conn, 404, %{success: false, error: "Not found"})
    end
  end

  defp managed_deploy(conn, manager, id, status) do
    with {:ok, definition, conn} <- read_json(conn),
         {:ok, workflow} <-
           FlowEngine.WorkflowManager.deploy(
             manager,
             id || FlowEngine.WorkflowManager.active(manager).id,
             definition
           ) do
      json(conn, status, workflow)
    else
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Workflow not found"})
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp serve_static(conn) do
    bundled = Application.app_dir(:flow_engine, "priv/static")
    source = Path.expand("../../priv/static", __DIR__)
    root = if File.exists?(Path.join(bundled, "index.html")), do: bundled, else: source

    if conn.method == "GET" and conn.request_path == "/" do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, Path.join(root, "index.html"))
      |> halt()
    else
      opts = Plug.Static.init(at: "/", from: root, gzip: false, index: "index.html")
      Plug.Static.call(conn, opts)
    end
  rescue
    _error -> conn
  end

  defp dispatch(conn, "GET", "/health/live", _engine, _registry),
    do: json(conn, 200, %{status: "ok"})

  defp dispatch(conn, "GET", "/health/ready", engine, _registry),
    do: json(conn, 200, %{status: "ok", workflow: FlowEngine.status(engine).status})

  defp dispatch(conn, "GET", "/api/health", engine, _registry),
    do:
      json(conn, 200, %{success: true, status: "ok", workflow: FlowEngine.status(engine).status})

  defp dispatch(conn, "GET", "/api/version", _engine, _registry),
    do: json(conn, 200, %{success: true, version: "0.1.0", websocketPreview: false})

  defp dispatch(conn, "GET", "/api/workflow", engine, _registry),
    do: json(conn, 200, FlowEngine.export_definition(engine))

  defp dispatch(conn, "GET", "/api/workflow/deployed", engine, _registry),
    do: json(conn, 200, FlowEngine.export_definition(engine))

  defp dispatch(conn, "GET", "/api/workflows", engine, _registry) do
    status = FlowEngine.status(engine)

    json(conn, 200, [
      %{
        id: "default",
        name: "Default Workflow",
        enabled: true,
        nodeCount: map_size(status.nodes),
        running: status.status == :running,
        active: true
      }
    ])
  end

  defp dispatch(conn, "GET", "/api/workflows/active", engine, _registry) do
    status = FlowEngine.status(engine)

    json(conn, 200, %{
      id: "default",
      name: "Default Workflow",
      enabled: true,
      active: true,
      running: status.status == :running,
      nodeCount: map_size(status.nodes)
    })
  end

  defp dispatch(conn, "PUT", "/api/workflows/active", _engine, _registry),
    do: json(conn, 200, %{success: true, activeWorkflow: "default"})

  defp dispatch(conn, "GET", "/api/nodes", engine, _registry) do
    %{nodes: nodes} = FlowEngine.status(engine)
    json(conn, 200, Enum.map(nodes, fn {id, node} -> Map.put(node, :id, id) end))
  end

  defp dispatch(conn, "GET", "/api/node-types", _engine, registry),
    do: json(conn, 200, node_types(registry))

  defp dispatch(conn, "GET", "/api/events", engine, _registry),
    do: json(conn, 200, FlowEngine.events(engine))

  defp dispatch(conn, "GET", "/api/events/stream", engine, _registry),
    do: events_stream(conn, engine, "default")

  defp dispatch(conn, "GET", "/api/debug/stream", engine, _registry),
    do: debug_stream(conn, engine, "default")

  defp dispatch(conn, "GET", "/api/link-channels", _engine, _registry),
    do: json(conn, 200, %{success: true, channels: []})

  defp dispatch(conn, method, "/api/nodes/" <> rest, engine, registry)
       when method in ["GET", "POST", "PUT", "DELETE"] do
    case String.split(rest, "/", parts: 2) do
      [id, "enabled"] when method == "GET" -> node_enabled(conn, engine, id)
      [id, "enabled"] when method == "POST" -> set_node_enabled(conn, engine, id)
      [id, "stats"] when method == "GET" -> node_stats(conn, engine, id)
      [id, "preview_stats"] when method == "GET" -> node_stats(conn, engine, id)
      [id, "debug"] when method == "GET" -> node_debug(conn, engine, id)
      [id, "position"] when method == "PUT" -> set_node_position(conn, engine, id)
      [id, action] when method == "POST" -> node_action(conn, engine, id, action)
      [id] when method == "GET" -> node_detail(conn, engine, id)
      [id] when method == "PUT" -> update_node(conn, engine, registry, id)
      [id] when method == "DELETE" -> delete_node(conn, engine, id)
      _ -> json(conn, 404, %{success: false, error: "Not found"})
    end
  end

  defp dispatch(conn, "POST", "/api/nodes", engine, registry),
    do: create_node(conn, engine, registry)

  defp dispatch(conn, "PUT", "/api/nodes/" <> id, engine, registry),
    do: update_node(conn, engine, registry, id)

  defp dispatch(conn, "DELETE", "/api/nodes/" <> id, engine, _registry),
    do: delete_node(conn, engine, id)

  defp dispatch(conn, "POST", "/api/connections", engine, _registry),
    do: create_connection(conn, engine)

  defp dispatch(conn, "DELETE", "/api/connections", engine, _registry),
    do: delete_connection(conn, engine)

  defp dispatch(conn, "POST", "/api/workflow", engine, registry),
    do: import_workflow(conn, engine, registry)

  defp dispatch(conn, "POST", "/api/workflow/deploy-changes", _engine, _registry),
    do:
      json(conn, 400, %{success: false, error: "Use /api/workflow/save with a complete workflow"})

  defp dispatch(conn, "POST", "/api/workflow/start", engine, _registry),
    do: command(conn, FlowEngine.start_workflow(engine))

  defp dispatch(conn, "POST", "/api/workflow/stop", engine, _registry),
    do: workflow_command(conn, FlowEngine.stop_workflow(engine), :stopped)

  # 旧前端把“重启”作为独立动作，语义是停止后立即启动当前工作流。
  defp dispatch(conn, "POST", "/api/workflow/restart", engine, _registry) do
    with :ok <- FlowEngine.stop_workflow(engine),
         :ok <- FlowEngine.start_workflow(engine) do
      json(conn, 200, %{success: true, restarted: 1})
    else
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp dispatch(conn, "POST", "/api/messages", engine, _registry), do: send_message(conn, engine)

  defp dispatch(conn, _method, _path, _engine, _registry),
    do: json(conn, 404, %{success: false, error: "Not found"})

  defp import_workflow(conn, engine, registry) do
    with {:ok, data, conn} <- read_json(conn),
         :ok <- FlowEngine.replace_definition(engine, data, registry) do
      json(conn, 201, FlowEngine.export_definition(engine))
    else
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp node_detail(conn, engine, id) do
    case FlowEngine.get_node(engine, id) do
      {:ok, node} -> json(conn, 200, node)
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
    end
  end

  defp create_node(conn, engine, registry) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, id} <- fetch(data, "id"),
         {:ok, type} <- fetch(data, "type"),
         module when is_atom(module) <- FlowEngine.NodeRegistry.resolve(registry, type),
         :ok <-
           FlowEngine.add_node(
             engine,
             id,
             module,
             Map.get(data, "config", %{}),
             %{
               type: Map.get(data, "type"),
               name: Map.get(data, "name"),
               x: Map.get(data, "x"),
               y: Map.get(data, "y")
             }
           ),
         {:ok, node} <- FlowEngine.get_node(engine, id) do
      json(conn, 201, node)
    else
      nil -> json(conn, 400, %{success: false, error: "Unknown node type"})
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp update_node(conn, engine, _registry, id) do
    with {:ok, data, conn} <- read_json(conn),
         attrs <- update_attrs(data),
         {:ok, node} <- FlowEngine.update_node(engine, id, attrs) do
      json(conn, 200, node)
    else
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp update_attrs(data) do
    metadata =
      data
      |> Map.take(["name", "type", "x", "y", "enabled"])
      |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)
      |> Map.new()

    data
    |> Map.put("metadata", metadata)
    |> Map.delete("name")
    |> Map.delete("type")
    |> Map.delete("x")
    |> Map.delete("y")
    |> Map.delete("enabled")
  end

  defp delete_node(conn, engine, id) do
    case FlowEngine.remove_node(engine, id) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
    end
  end

  defp create_connection(conn, engine) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, source} <- fetch(data, "source"),
         {:ok, target} <- fetch(data, "target"),
         :ok <-
           FlowEngine.connect(
             engine,
             source,
             Map.get(data, "sourceOutput", 0),
             target,
             Map.get(data, "targetInput", 0)
           ) do
      json(conn, 201, %{
        "source" => source,
        "target" => target,
        "sourceOutput" => Map.get(data, "sourceOutput", 0),
        "targetInput" => Map.get(data, "targetInput", 0)
      })
    else
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp delete_connection(conn, engine) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, source} <- fetch(data, "source"),
         {:ok, target} <- fetch(data, "target"),
         :ok <-
           FlowEngine.disconnect(
             engine,
             source,
             Map.get(data, "sourceOutput", 0),
             target,
             Map.get(data, "targetInput", 0)
           ) do
      send_resp(conn, 204, "")
    else
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp send_message(conn, engine) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, node_id} <- fetch(data, "nodeId"),
         {:ok, message} <- fetch(data, "message"),
         input_port = Map.get(data, "inputPort", 0),
         :ok <- FlowEngine.send_message(engine, node_id, input_port, message) do
      json(conn, 202, %{success: true})
    else
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp workflow_command(conn, :ok, key), do: json(conn, 200, Map.put(%{success: true}, key, 1))

  defp workflow_command(conn, {:error, reason}, _key),
    do: json(conn, 400, %{success: false, error: inspect(reason)})

  defp node_enabled(conn, engine, id) do
    case FlowEngine.get_node(engine, id) do
      {:ok, node} -> json(conn, 200, %{success: true, enabled: Map.get(node, "enabled", true)})
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
    end
  end

  defp set_node_enabled(conn, engine, id) do
    case read_json(conn) do
      {:ok, data, conn} ->
        case Map.get(data, "enabled") do
          enabled when is_boolean(enabled) ->
            case FlowEngine.update_node_metadata(engine, id, %{enabled: enabled}) do
              {:ok, node} ->
                json(conn, 200, %{success: true, enabled: Map.get(node, "enabled", enabled)})

              {:error, :not_found} ->
                json(conn, 404, %{success: false, error: "Node not found"})

              {:error, reason} ->
                json(conn, 400, %{success: false, error: inspect(reason)})
            end

          _ ->
            json(conn, 400, %{success: false, error: "enabled must be boolean"})
        end

      {:error, reason} ->
        json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp set_node_position(conn, engine, id) do
    with {:ok, data, conn} <- read_json(conn),
         {:ok, node} <-
           FlowEngine.update_node_metadata(engine, id, %{
             x: Map.get(data, "x"),
             y: Map.get(data, "y")
           }) do
      json(conn, 200, node)
    else
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
      {:error, reason} -> json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp node_stats(conn, engine, id) do
    case FlowEngine.get_node(engine, id) do
      {:ok, _node} ->
        json(conn, 200, %{
          success: true,
          nodeId: id,
          transport: "none",
          fps: 0,
          jpegKbps: 0,
          avgJpegBytes: 0,
          websocketFps: 0,
          websocketKbps: 0,
          avgWebsocketBytes: 0,
          sseFps: 0,
          sseKbps: 0,
          avgSseBytes: 0,
          queueLength: 0
        })

      {:error, :not_found} ->
        json(conn, 404, %{success: false, error: "Node not found"})
    end
  end

  defp node_debug(conn, engine, id) do
    case FlowEngine.get_node(engine, id) do
      {:ok, _node} -> json(conn, 200, %{success: true, nodeId: id, messages: []})
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
    end
  end

  defp node_action(conn, engine, id, action) do
    case FlowEngine.get_node(engine, id) do
      {:ok, _node} -> json(conn, 200, %{success: true, nodeId: id, action: action})
      {:error, :not_found} -> json(conn, 404, %{success: false, error: "Node not found"})
    end
  end

  defp save_workflow(conn, _engine, _registry, nil) do
    json(conn, 400, %{success: false, error: "persistence_path is not configured"})
  end

  defp save_workflow(conn, engine, registry, path) do
    case read_optional_json(conn) do
      {:ok, nil, conn} ->
        persist_definition(conn, engine, path)

      {:ok, definition, conn} ->
        snapshot = FlowEngine.checkpoint_snapshot(engine)

        case FlowEngine.replace_definition(engine, definition, registry) do
          :ok ->
            case FlowEngine.Persistence.save(path, FlowEngine.export_definition(engine)) do
              :ok ->
                :ok = FlowEngine.start_workflow(engine)

                json(conn, 200, %{
                  success: true,
                  path: path,
                  workflow: FlowEngine.export_definition(engine)
                })

              {:error, reason} ->
                case FlowEngine.restore_checkpoint(engine, snapshot) do
                  :ok ->
                    json(conn, 500, %{success: false, error: inspect(reason)})

                  {:error, restore_reason} ->
                    json(conn, 500, %{
                      success: false,
                      error: inspect({:rollback_failed, reason, restore_reason})
                    })
                end
            end

          {:error, reason} ->
            json(conn, 400, %{success: false, error: inspect(reason)})
        end

      {:error, reason} ->
        json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  defp persist_definition(conn, engine, path) do
    definition = FlowEngine.export_definition(engine)

    case FlowEngine.Persistence.save(path, definition) do
      :ok -> json(conn, 200, %{success: true, path: path, workflow: definition})
      {:error, reason} -> json(conn, 500, %{success: false, error: inspect(reason)})
    end
  end

  defp read_json(conn) do
    case read_body(conn) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data, conn}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      error ->
        error
    end
  end

  defp read_optional_json(conn) do
    case read_body(conn) do
      {:ok, <<>>, conn} ->
        {:ok, nil, conn}

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) -> {:ok, data, conn}
          {:ok, _data} -> {:error, :invalid_workflow_shape}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      error ->
        error
    end
  end

  defp fetch(map, key),
    do: if(Map.has_key?(map, key), do: {:ok, Map.get(map, key)}, else: {:error, {:missing, key}})

  defp command(conn, :ok), do: json(conn, 200, %{success: true})

  defp command(conn, {:error, reason}),
    do: json(conn, 400, %{success: false, error: inspect(reason)})

  defp node_types(%FlowEngine.NodeRegistry{types: types}) do
    Enum.map(types, fn {type, module} ->
      visual = node_visual(type)
      Map.merge(%{type: type, name: type, module: inspect(module)}, visual)
    end)
  end

  defp node_visual("ChangeNode"),
    do: %{
      name: "Change",
      properties: [
        %{
          name: "rules",
          label: "规则",
          type: "changeRules",
          default: [],
          operations: ["set"],
          valueTypes: ["str", "num", "bool"]
        }
      ],
      icon: "✎",
      category: "function",
      color: "#E6E0F8",
      borderColor: "#9F93C6",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1
    }

  defp node_visual("SwitchNode"),
    do: %{
      name: "Switch",
      properties: [
        %{name: "property", label: "判断字段", type: "text", default: "msg.payload"},
        %{
          name: "rules",
          label: "路由规则",
          type: "rules",
          operators: ["eq", "neq", "gt", "gte", "lt", "lte", "else"],
          valueTypes: ["str", "num", "bool"],
          default: [%{operator: "eq", value: "", valueType: "str"}]
        },
        %{name: "checkall", label: "匹配所有规则", type: "checkbox", default: false}
      ],
      icon: "⎇",
      category: "logic",
      color: "#E9967A",
      borderColor: "#CA7C5F",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1
    }

  defp node_visual("CounterNode"),
    do: %{
      name: "Counter",
      properties: [
        %{name: "initial_value", label: "初始值", type: "number", default: 0},
        %{name: "increment", label: "每次增加", type: "number", default: 1}
      ],
      icon: "🔢",
      category: "node probes",
      color: "#E2D96E",
      borderColor: "#B8AF4A",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1
    }

  defp node_visual("PassThroughNode"),
    do: %{
      name: "Pass Through",
      properties: [],
      icon: "→",
      category: "common",
      color: "#D9EAF7",
      borderColor: "#4A90C2",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1
    }

  defp node_visual("CameraNode"),
    do: %{
      name: "Hik Camera",
      icon: "📷",
      category: "camera",
      color: "#D9EAF7",
      borderColor: "#4A90C2",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1,
      properties: [
        %{name: "serial", label: "相机序列号", type: "text", default: ""},
        %{name: "base_url", label: "相机服务地址", type: "text", default: "http://127.0.0.1:8080"},
        %{
          name: "action",
          label: "操作",
          type: "select",
          default: "trigger",
          options: [
            %{value: "trigger", label: "软件触发"},
            %{value: "status", label: "查询状态"}
          ]
        },
        %{name: "timeout_ms", label: "超时（毫秒）", type: "number", default: 3000},
        %{name: "token", label: "访问令牌", type: "password", default: ""}
      ]
    }

  defp node_visual(type) when type in ["VisionNode", "InferenceNode"],
    do: %{
      name: if(type == "VisionNode", do: "Python Vision", else: "Python Inference"),
      icon: "◉",
      category: "vision",
      color: "#DDEAD7",
      borderColor: "#6B9B6F",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1,
      properties: [
        %{name: "url", label: "服务接口地址", type: "text", default: ""},
        %{name: "operation", label: "操作名称", type: "text", default: ""},
        %{name: "timeout_ms", label: "超时（毫秒）", type: "number", default: 5000},
        %{name: "token", label: "访问令牌", type: "password", default: ""}
      ]
    }

  defp node_visual("PLCNode"),
    do: %{
      name: "PLC",
      icon: "PLC",
      category: "plc",
      color: "#F4E6CA",
      borderColor: "#B69659",
      textColor: "#000000",
      inputCount: 1,
      outputCount: 1,
      properties: [
        %{
          name: "action",
          label: "操作",
          type: "select",
          default: "read",
          options: [
            %{value: "read", label: "读取"},
            %{value: "write", label: "写入"}
          ]
        },
        %{name: "base_url", label: "PLC 服务地址", type: "text", default: "http://127.0.0.1:4001"},
        %{name: "device_id", label: "设备 ID", type: "text", default: ""},
        %{name: "token", label: "访问令牌", type: "password", default: ""},
        %{name: "db", label: "DB 编号", type: "number", default: 1},
        %{name: "offset", label: "偏移", type: "number", default: 0},
        %{
          name: "point_type",
          label: "数据类型",
          type: "select",
          default: "int16",
          options: [
            %{value: "bool", label: "布尔值"},
            %{value: "int16", label: "16 位有符号整数"},
            %{value: "uint16", label: "16 位无符号整数"},
            %{value: "int32", label: "32 位有符号整数"},
            %{value: "uint32", label: "32 位无符号整数"},
            %{value: "float32", label: "32 位浮点数"},
            %{value: "string", label: "字符串"},
            %{value: "bytes", label: "字节数组"}
          ]
        },
        %{
          name: "bit",
          label: "位号（0-7）",
          type: "number",
          default: 0,
          showIf: %{point_type: "bool"}
        },
        %{
          name: "size",
          label: "长度",
          type: "number",
          default: 1,
          showIf: %{point_type: ["string", "bytes"]}
        },
        %{name: "timeout_ms", label: "超时（毫秒）", type: "number", default: 3000}
      ]
    }

  defp node_visual(_type),
    do: %{icon: "◆", category: "custom", inputCount: 1, outputCount: 1, properties: []}

  # 订阅与快照在引擎内原子完成，避免连接建立期间丢事件。
  defp events_stream(conn, engine, workflow_id),
    do: stream_events(conn, engine, workflow_id, :runtime)

  defp debug_stream(conn, engine, workflow_id),
    do: stream_events(conn, engine, workflow_id, :debug)

  defp stream_events(conn, engine, workflow_id, mode) do
    events = FlowEngine.subscribe(engine)
    monitor = Process.monitor(engine)

    try do
      conn =
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      last_id = last_event_id(conn)

      initial =
        if mode == :debug, do: ["data: {\"type\":\"connected\"}\n\n"], else: [": connected\n\n"]

      with {:ok, conn} <- send_chunks(conn, initial),
           {:ok, conn} <-
             send_chunks(
               conn,
               Enum.flat_map(events, &event_payload(&1, mode, workflow_id, last_id))
             ) do
        if conn.private[:flow_engine_stream_once] do
          conn
        else
          stream_loop(conn, engine, monitor, workflow_id, mode)
        end
      else
        {:error, conn} -> conn
      end
    after
      Process.demonitor(monitor, [:flush])

      try do
        FlowEngine.unsubscribe(engine)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp send_chunks(conn, payloads) do
    Enum.reduce_while(payloads, {:ok, conn}, fn payload, {:ok, current} ->
      case chunk(current, payload) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} -> {:halt, {:error, current}}
      end
    end)
  end

  defp stream_loop(conn, engine, monitor, workflow_id, mode) do
    receive do
      {:flow_event, ^engine, event} ->
        case send_chunks(conn, event_payload(event, mode, workflow_id, 0)) do
          {:ok, next} -> stream_loop(next, engine, monitor, workflow_id, mode)
          {:error, _} -> conn
        end

      {:DOWN, ^monitor, :process, ^engine, _reason} ->
        conn
    after
      15_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, next} -> stream_loop(next, engine, monitor, workflow_id, mode)
          {:error, _reason} -> conn
        end
    end
  end

  defp event_payload(%{id: id} = event, :runtime, workflow_id, last_id) when id > last_id do
    data = Jason.encode!(Map.put(event, :workflowId, workflow_id), fallback: &inspect/1)
    [["id: ", Integer.to_string(id), "\nevent: runtime\ndata: ", data, "\n\n"]]
  end

  defp event_payload(%{id: id} = event, :debug, workflow_id, last_id) when id > last_id do
    payload = debug_payload(event, workflow_id)

    [
      [
        "id: ",
        Integer.to_string(id),
        "\ndata: ",
        Jason.encode!(payload, fallback: &inspect/1),
        "\n\n"
      ]
    ]
  end

  defp event_payload(_event, _mode, _workflow_id, _last_id), do: []

  defp debug_payload(event, workflow_id) do
    timestamp = event.timestamp / 1000

    case event.type do
      :error ->
        %{
          type: "errors",
          workflowId: workflow_id,
          data: [
            %{
              source_node_id: event.node_id,
              source_node_name: to_string(event.node_id),
              message: inspect(event.details, limit: 12, printable_limit: 512),
              timestamp: timestamp
            }
          ]
        }

      :output ->
        %{
          type: "messages",
          workflowId: workflow_id,
          data: [
            %{
              node_id: event.node_id,
              node: to_string(event.node_id),
              output: event.details.preview,
              timestamp:
                Calendar.strftime(DateTime.from_unix!(event.timestamp, :millisecond), "%H:%M:%S")
            }
          ]
        }

      _ ->
        %{type: "runtime", workflowId: workflow_id, data: event}
    end
  end

  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [value | _] ->
        case Integer.parse(value) do
          {id, ""} when id >= 0 -> id
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
