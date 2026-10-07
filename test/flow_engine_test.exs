defmodule FlowEngineTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2, put_private: 3, put_req_header: 3]

  defmodule Forward do
    @behaviour FlowEngine.Node
    def init(config), do: {:ok, config}
    def handle_message(_, message, state), do: {:emit, [{0, {state, message}}], state}
  end

  defmodule Sink do
    @behaviour FlowEngine.Node
    def init(%{"parent" => parent}), do: {:ok, parent}
    def init(parent), do: {:ok, parent}

    def handle_message(_, message, parent) do
      send(parent, {:received, message})
      {:ok, parent}
    end
  end

  defmodule Counter do
    @behaviour FlowEngine.Node
    def init(parent), do: {:ok, parent}

    def handle_message(_, count, parent) when count < 3 do
      send(parent, {:count, count})
      {:emit, [{0, count + 1}], parent}
    end

    def handle_message(_, count, parent) do
      send(parent, {:count, count})
      {:ok, parent}
    end
  end

  defmodule RejectConfig do
    @behaviour FlowEngine.Node
    def init(_config), do: {:error, :invalid_config}
    def handle_message(_port, _message, state), do: {:ok, state}
  end

  test "替换工作流失败时恢复原有运行节点" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, "existing", Forward, %{})
    :ok = FlowEngine.start_workflow(flow)

    workflow = %{"nodes" => [%{"id" => "bad", "type" => "reject"}], "connections" => []}

    assert {:error, _reason} =
             FlowEngine.replace_definition(flow, workflow, fn "reject" -> RejectConfig end)

    assert FlowEngine.status(flow).status == :running
    assert {:ok, _node} = FlowEngine.get_node(flow, "existing")
    assert {:error, :not_found} = FlowEngine.get_node(flow, "bad")
  end

  test "通过节点转发消息" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :source, Forward, :source)
    :ok = FlowEngine.add_node(flow, :sink, Sink, self())
    :ok = FlowEngine.connect(flow, :source, 0, :sink, 0)
    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, :source, 0, :hello)
    assert_receive {:received, {:source, :hello}}, 500
  end

  test "禁用节点不会处理消息，重新启用后恢复" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :source, Forward, :source)
    :ok = FlowEngine.add_node(flow, :sink, Sink, self(), %{enabled: false})
    :ok = FlowEngine.connect(flow, :source, 0, :sink, 0)
    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, :source, 0, :ignored)
    refute_receive {:received, _message}, 50

    assert {:ok, _node} = FlowEngine.update_node_metadata(flow, :sink, %{enabled: true})
    :ok = FlowEngine.send_message(flow, :source, 0, :delivered)
    assert_receive {:received, {:source, :delivered}}, 500
  end

  test "支持有界环路" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :left, Counter, self())
    :ok = FlowEngine.add_node(flow, :right, Counter, self())
    :ok = FlowEngine.connect(flow, :left, 0, :right, 0)
    :ok = FlowEngine.connect(flow, :right, 0, :left, 0)
    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, :left, 0, 0)

    assert_receive {:count, 0}, 500
    assert_receive {:count, 1}, 500
    assert_receive {:count, 2}, 500
    assert_receive {:count, 3}, 500
  end

  test "加载现有的节点和连接格式" do
    {:ok, flow} = FlowEngine.start_link()

    workflow = %{
      "nodes" => [
        %{"id" => "source", "type" => "forward", "config" => %{"name" => "demo"}},
        %{"id" => "sink", "type" => "sink", "config" => %{"parent" => self()}}
      ],
      "connections" => [
        %{"source" => "source", "target" => "sink", "sourceOutput" => 0, "targetInput" => 0}
      ]
    }

    resolver = fn
      "forward" -> Forward
      "sink" -> Sink
      _ -> nil
    end

    assert :ok = FlowEngine.WorkflowLoader.load(flow, workflow, resolver)
    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, "source", 0, :loaded)
    assert_receive {:received, {%{"name" => "demo"}, :loaded}}, 500

    definition = FlowEngine.export_definition(flow)
    source = Enum.find(definition["nodes"], &(&1["id"] == "source"))
    assert source["type"] == "forward"
    assert source["x"] == nil
    assert source["config"] == %{"name" => "demo"}

    assert [%{"source" => "source", "target" => "sink", "sourceOutput" => 0, "targetInput" => 0}] =
             definition["connections"]
  end

  test "通过注册表解析节点类型" do
    {:ok, flow} = FlowEngine.start_link()

    registry =
      FlowEngine.NodeRegistry.new()
      |> FlowEngine.NodeRegistry.register!("forward", Forward)
      |> FlowEngine.NodeRegistry.register!("sink", Sink)

    workflow = %{
      "nodes" => [
        %{"id" => "source", "type" => "forward"},
        %{"id" => "sink", "type" => "sink", "config" => %{"parent" => self()}}
      ],
      "connections" => [%{"source" => "source", "target" => "sink"}]
    }

    assert :ok = FlowEngine.WorkflowLoader.load(flow, workflow, registry)
    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, "source", 0, :registered)
    assert_receive {:received, {%{}, :registered}}, 500
  end

  test "计数节点使用初始值和增量" do
    {:ok, state} = FlowEngine.Nodes.Counter.init(%{"initial_value" => 5, "increment" => 2})
    {:emit, [{0, first}], next_state} = FlowEngine.Nodes.Counter.handle_message(0, %{}, state)
    {:emit, [{0, second}], _} = FlowEngine.Nodes.Counter.handle_message(0, %{}, next_state)

    assert first["payload"]["count"] == 7
    assert second["payload"]["count"] == 9
  end

  test "内置修改和分支节点保留消息结构" do
    {:ok, change_state} =
      FlowEngine.Nodes.Change.init(%{
        "rules" => [
          %{"type" => "set", "path" => "msg.topic", "value" => "high", "valueType" => "str"}
        ]
      })

    {:emit, [{0, changed}], _} =
      FlowEngine.Nodes.Change.handle_message(0, %{"payload" => 0.8}, change_state)

    assert changed["topic"] == "high"

    {:ok, switch_state} =
      FlowEngine.Nodes.Switch.init(%{
        "property" => "msg.payload",
        "rules" => [
          %{"operator" => "gte", "value" => "0.5", "valueType" => "num"},
          %{"operator" => "else"}
        ]
      })

    {:emit, [{0, _}], _} =
      FlowEngine.Nodes.Switch.handle_message(0, %{"payload" => 0.8}, switch_state)
  end

  test "records runtime events" do
    {:ok, flow} = FlowEngine.start_link(max_hops: 1)
    :ok = FlowEngine.add_node(flow, :source, Forward, :source)
    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, :source, 0, :event)
    assert Enum.any?(FlowEngine.events(flow), &(&1.type == :started))
  end

  test "实时订阅运行事件并在取消后停止推送" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :source, Forward, :source)
    snapshot = FlowEngine.subscribe(flow)
    assert is_list(snapshot)

    :ok = FlowEngine.start_workflow(flow)
    :ok = FlowEngine.send_message(flow, :source, 0, :event)
    assert_receive {:flow_event, ^flow, %{type: :output, details: %{preview: preview}}}, 1000
    assert preview =~ "event"

    :ok = FlowEngine.unsubscribe(flow)
    :ok = FlowEngine.send_message(flow, :source, 0, :again)
    refute_receive {:flow_event, ^flow, %{type: :output}}, 100
  end

  test "支持查询、更新节点和断开连接" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :source, Forward, :old, %{type: "forward", x: 10})
    :ok = FlowEngine.add_node(flow, :sink, Sink, self())
    :ok = FlowEngine.connect(flow, :source, 0, :sink, 0)

    assert {:ok, node} = FlowEngine.get_node(flow, :source)
    assert node["x"] == 10

    assert {:ok, _} = FlowEngine.update_node_metadata(flow, :source, %{x: 20, y: 30})
    assert {:ok, updated} = FlowEngine.get_node(flow, :source)
    assert updated["x"] == 20
    assert updated["y"] == 30

    assert :ok = FlowEngine.disconnect(flow, :source, 0, :sink, 0)
    assert {:error, :not_found} = FlowEngine.disconnect(flow, :source, 0, :sink, 0)
  end

  test "支持重置和替换工作流定义" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :old, Forward)
    assert {:ok, _} = FlowEngine.get_node(flow, :old)
    assert :ok = FlowEngine.reset(flow)
    assert {:error, :not_found} = FlowEngine.get_node(flow, :old)

    workflow = %{"nodes" => [%{"id" => "new", "type" => "forward"}], "connections" => []}
    assert :ok = FlowEngine.replace_definition(flow, workflow, fn "forward" -> Forward end)
    assert {:ok, node} = FlowEngine.get_node(flow, "new")
    assert node["type"] == "forward"
  end

  test "HTTP 接口提供健康检查和 workflow 导入导出" do
    {:ok, flow} = FlowEngine.start_link()
    opts = [engine: flow, registry: FlowEngine.NodeRegistry.builtins()]

    health = conn(:get, "/health/live") |> FlowEngine.HttpRouter.call(opts)
    assert health.status == 200
    assert Jason.decode!(health.resp_body)["status"] == "ok"

    body =
      Jason.encode!(%{
        "nodes" => [%{"id" => "pass", "type" => "PassThroughNode"}],
        "connections" => []
      })

    imported =
      conn(:post, "/api/workflow", body)
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(opts)

    assert imported.status == 201

    exported = conn(:get, "/api/workflow") |> FlowEngine.HttpRouter.call(opts)
    assert exported.status == 200

    assert [%{"id" => "pass", "type" => "PassThroughNode"}] =
             Jason.decode!(exported.resp_body)["nodes"]
  end

  test "HTTP SSE 事件接口返回事件流" do
    {:ok, flow} = FlowEngine.start_link()
    opts = [engine: flow, registry: FlowEngine.NodeRegistry.builtins()]
    :ok = FlowEngine.add_node(flow, :source, Forward, :source)
    :ok = FlowEngine.start_workflow(flow)

    response =
      conn(:get, "/api/events/stream")
      |> put_private(:flow_engine_stream_once, true)
      |> FlowEngine.HttpRouter.call(opts)

    assert response.status == 200
    assert [content_type] = get_resp_header(response, "content-type")
    assert String.starts_with?(content_type, "text/event-stream")
    assert response.resp_body =~ "event: runtime"
    assert response.resp_body =~ "data:"
    assert response.resp_body =~ ": connected"
  end

  test "旧前端调试流把输出和错误转为兼容格式" do
    {:ok, flow} = FlowEngine.start_link()
    send(flow, {:node_output, "source", 0, %{payload: "hello"}, 0})
    send(flow, {:node_event, "source", :error, :failed})

    response =
      conn(:get, "/api/debug/stream")
      |> put_private(:flow_engine_stream_once, true)
      |> FlowEngine.HttpRouter.call(engine: flow)

    assert response.status == 200
    assert response.resp_body =~ ~s("type":"messages")
    assert response.resp_body =~ ~s("type":"errors")
    assert response.resp_body =~ ~s("workflowId":"default")
    assert response.resp_body =~ "hello"
  end

  test "原子保存和备用文件恢复 workflow" do
    path = Path.join(System.tmp_dir!(), "flow-engine-#{System.unique_integer([:positive])}.json")
    definition = %{"nodes" => [], "connections" => []}
    assert :ok = FlowEngine.Persistence.save(path, definition)
    assert {:ok, ^definition} = FlowEngine.Persistence.load(path)
    assert :ok = FlowEngine.Persistence.save(path, definition)

    File.write!(path, "invalid")
    assert {:ok, ^definition, :backup} = FlowEngine.Persistence.load_with_backup(path)
    File.rm(path)
    File.rm(path <> ".bak")
  end

  test "checkpoint 保存并恢复节点运行态" do
    {:ok, flow} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(flow, :source, Forward, %{value: 42}, %{type: "forward"})
    :ok = FlowEngine.start_workflow(flow)

    path =
      Path.join(System.tmp_dir!(), "flow-checkpoint-#{System.unique_integer([:positive])}.bin")

    assert :ok = FlowEngine.Checkpoint.save(flow, path)
    assert is_map(FlowEngine.Checkpoint.snapshot(flow))
    :ok = FlowEngine.reset(flow)
    assert :ok = FlowEngine.Checkpoint.load(flow, path)
    assert {:ok, node} = FlowEngine.get_node(flow, :source)
    assert node["config"] == %{value: 42}
    assert FlowEngine.status(flow).status == :running
    File.rm(path)
  end
end
