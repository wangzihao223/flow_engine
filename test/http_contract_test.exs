defmodule FlowEngine.HttpContractTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  defp call(method, path, body \\ "") do
    {:ok, engine} = FlowEngine.start_link()
    opts = [engine: engine, registry: FlowEngine.NodeRegistry.builtins()]

    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> FlowEngine.HttpRouter.call(opts)
  end

  test "未知路由返回统一的 404 JSON" do
    response = call(:get, "/api/unknown")

    assert response.status == 404
    assert Jason.decode!(response.resp_body) == %{"success" => false, "error" => "Not found"}
  end

  test "工作流接口拒绝无效 JSON" do
    response = call(:post, "/api/workflow", "{")

    assert response.status == 400
    assert Jason.decode!(response.resp_body)["success"] == false
  end

  test "消息接口校验必需字段并报告不存在节点" do
    missing_message = call(:post, "/api/messages", Jason.encode!(%{"nodeId" => "missing"}))
    assert missing_message.status == 400
    assert Jason.decode!(missing_message.resp_body)["success"] == false

    missing_node =
      call(:post, "/api/messages", Jason.encode!(%{"nodeId" => "missing", "message" => %{}}))

    assert missing_node.status == 400
    assert Jason.decode!(missing_node.resp_body)["success"] == false
  end

  test "工作流启停通过 HTTP 反映运行状态" do
    {:ok, engine} = FlowEngine.start_link()
    opts = [engine: engine, registry: FlowEngine.NodeRegistry.builtins()]

    stopped = Plug.Test.conn(:get, "/health/ready") |> FlowEngine.HttpRouter.call(opts)
    assert Jason.decode!(stopped.resp_body)["workflow"] == "stopped"

    started =
      Plug.Test.conn(:post, "/api/workflow/start")
      |> FlowEngine.HttpRouter.call(opts)

    assert started.status == 200
    assert Jason.decode!(started.resp_body)["success"] == true

    ready = Plug.Test.conn(:get, "/health/ready") |> FlowEngine.HttpRouter.call(opts)
    assert Jason.decode!(ready.resp_body)["workflow"] == "running"

    stopped_again =
      Plug.Test.conn(:post, "/api/workflow/stop")
      |> FlowEngine.HttpRouter.call(opts)

    assert stopped_again.status == 200
    assert Jason.decode!(stopped_again.resp_body)["success"] == true
  end

  test "节点类型接口返回注册表中的类型" do
    response = call(:get, "/api/node-types")
    types = Jason.decode!(response.resp_body)

    assert response.status == 200
    assert Enum.any?(types, &(&1["type"] == "PassThroughNode"))
    assert Enum.find(types, &(&1["type"] == "ChangeNode"))["icon"] == "✎"
    assert Enum.find(types, &(&1["type"] == "SwitchNode"))["icon"] == "⎇"
    assert Enum.find(types, &(&1["type"] == "CounterNode"))["icon"] == "🔢"
    change = Enum.find(types, &(&1["type"] == "ChangeNode"))
    switch = Enum.find(types, &(&1["type"] == "SwitchNode"))
    counter = Enum.find(types, &(&1["type"] == "CounterNode"))
    assert Enum.find(change["properties"], &(&1["name"] == "rules"))["type"] == "changeRules"
    assert Enum.find(switch["properties"], &(&1["name"] == "rules"))["type"] == "rules"

    assert Enum.find(switch["properties"], &(&1["name"] == "property"))["default"] ==
             "msg.payload"

    assert Enum.find(counter["properties"], &(&1["name"] == "increment"))["default"] == 1

    camera = Enum.find(types, &(&1["type"] == "CameraNode"))
    vision = Enum.find(types, &(&1["type"] == "VisionNode"))
    inference = Enum.find(types, &(&1["type"] == "InferenceNode"))
    plc = Enum.find(types, &(&1["type"] == "PLCNode"))

    assert Enum.any?(camera["properties"], &(&1["name"] == "serial"))
    assert Enum.any?(vision["properties"], &(&1["name"] == "url"))
    assert Enum.any?(inference["properties"], &(&1["name"] == "operation"))
    assert Enum.find(plc["properties"], &(&1["name"] == "base_url"))["type"] == "text"
    assert Enum.find(plc["properties"], &(&1["name"] == "device_id"))["type"] == "text"
    assert Enum.find(plc["properties"], &(&1["name"] == "token"))["type"] == "password"
    assert Enum.find(plc["properties"], &(&1["name"] == "point_type"))["type"] == "select"

    assert Enum.find(plc["properties"], &(&1["name"] == "bit"))["showIf"] == %{
             "point_type" => "bool"
           }

    refute Enum.any?(plc["properties"], &(&1["name"] == "connection"))
  end

  @tag :tmp_dir
  test "部署保存工作流并在无效配置时保留旧版本", %{tmp_dir: directory} do
    {:ok, engine} = FlowEngine.start_link()
    path = Path.join(directory, "workflow.json")
    opts = [engine: engine, registry: FlowEngine.NodeRegistry.builtins(), persistence_path: path]

    definition = %{
      "nodes" => [
        %{"id" => "source", "type" => "PassThroughNode", "config" => %{}, "enabled" => false},
        %{"id" => "counter", "type" => "CounterNode", "config" => %{"increment" => 2}}
      ],
      "connections" => [%{"source" => "source", "target" => "counter"}]
    }

    response =
      conn(:post, "/api/workflow/save", Jason.encode!(definition))
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(opts)

    assert response.status == 200
    assert FlowEngine.status(engine).status == :running
    {:ok, saved} = FlowEngine.Persistence.load(path)
    assert saved == FlowEngine.export_definition(engine)
    assert Enum.find(saved["nodes"], &(&1["id"] == "source"))["enabled"] == false

    invalid = %{"nodes" => [%{"id" => "bad", "type" => "UnknownNode"}], "connections" => []}

    failed =
      conn(:post, "/api/workflow/save", Jason.encode!(invalid))
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(opts)

    assert failed.status == 400
    assert FlowEngine.export_definition(engine) == saved
    assert FlowEngine.status(engine).status == :running
    assert FlowEngine.Persistence.load(path) == {:ok, saved}

    {:ok, restored_engine} = FlowEngine.start_link()

    {:ok, server} =
      FlowEngine.HttpServer.start_link(engine: restored_engine, port: 0, persistence_path: path)

    assert FlowEngine.export_definition(restored_engine) == saved
    GenServer.stop(server)

    empty_body =
      conn(:post, "/api/workflow/save", "{}")
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(opts)

    assert empty_body.status == 400
    assert FlowEngine.export_definition(engine) == saved

    blocked_path = Path.join(directory, "blocked")
    :ok = File.mkdir_p(blocked_path)
    blocked_opts = Keyword.put(opts, :persistence_path, blocked_path)
    changed = %{"nodes" => [], "connections" => []}

    write_failed =
      conn(:post, "/api/workflow/save", Jason.encode!(changed))
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(blocked_opts)

    assert write_failed.status == 500
    assert FlowEngine.export_definition(engine) == saved
    assert FlowEngine.status(engine).status == :running
  end
end
