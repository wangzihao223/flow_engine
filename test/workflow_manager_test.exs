defmodule FlowEngine.WorkflowManagerTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  defp request(opts, method, path, body \\ "") do
    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> FlowEngine.HttpRouter.call(opts)
  end

  @tag :tmp_dir
  test "工作流独立部署、切换、禁用和重启恢复", %{tmp_dir: directory} do
    path = Path.join(directory, "workflows.json")
    registry = FlowEngine.NodeRegistry.builtins()
    {:ok, default_engine} = FlowEngine.start_link()

    {:ok, manager} =
      FlowEngine.WorkflowManager.start_link(
        engine: default_engine,
        registry: registry,
        persistence_path: path
      )

    opts = [engine: default_engine, manager: manager, registry: registry, persistence_path: path]
    created = request(opts, :post, "/api/workflows", Jason.encode!(%{name: "Vision"}))
    assert created.status == 201
    id = Jason.decode!(created.resp_body)["id"]

    activated = request(opts, :put, "/api/workflows/active", Jason.encode!(%{workflowId: id}))
    assert Jason.decode!(activated.resp_body)["activeWorkflow"] == id

    definition = %{
      "nodes" => [%{"id" => "counter", "type" => "CounterNode", "config" => %{"increment" => 3}}],
      "connections" => []
    }

    deployed =
      request(opts, :post, "/api/workflow/save?workflow=#{id}", Jason.encode!(definition))

    assert deployed.status == 200

    assert length(
             Jason.decode!(request(opts, :get, "/api/workflow?workflow=#{id}").resp_body)["nodes"]
           ) == 1

    assert Jason.decode!(request(opts, :get, "/api/workflow?workflow=default").resp_body)["nodes"] ==
             []

    disabled = request(opts, :put, "/api/workflows/#{id}", Jason.encode!(%{enabled: false}))
    assert Jason.decode!(disabled.resp_body)["running"] == false

    assert FlowEngine.status(elem(FlowEngine.WorkflowManager.engine(manager, id), 1)).status ==
             :stopped

    {:ok, restarted_engine} = FlowEngine.start_link()

    {:ok, restarted_manager} =
      FlowEngine.WorkflowManager.start_link(
        engine: restarted_engine,
        registry: registry,
        persistence_path: path
      )

    restarted_opts = [engine: restarted_engine, manager: restarted_manager, registry: registry]
    workflows = Jason.decode!(request(restarted_opts, :get, "/api/workflows").resp_body)
    assert length(workflows) == 2
    assert Enum.find(workflows, &(&1["id"] == id))["enabled"] == false

    assert Jason.decode!(request(restarted_opts, :get, "/api/workflows/active").resp_body)["id"] ==
             id

    assert length(
             Jason.decode!(
               request(restarted_opts, :get, "/api/workflow?workflow=#{id}").resp_body
             )["nodes"]
           ) == 1

    deleted = request(opts, :delete, "/api/workflows/#{id}")
    assert Jason.decode!(deleted.resp_body)["activeWorkflow"] == "default"
    assert request(opts, :delete, "/api/workflows/default").status == 400
  end

  @tag :tmp_dir
  test "旧版单工作流文件可迁移", %{tmp_dir: directory} do
    path = Path.join(directory, "workflow.json")
    legacy = %{"nodes" => [%{"id" => "old", "type" => "PassThroughNode"}], "connections" => []}
    :ok = FlowEngine.Persistence.save(path, legacy)
    {:ok, engine} = FlowEngine.start_link()

    {:ok, manager} =
      FlowEngine.WorkflowManager.start_link(
        engine: engine,
        registry: FlowEngine.NodeRegistry.builtins(),
        persistence_path: path
      )

    assert {:ok, ^engine} = FlowEngine.WorkflowManager.engine(manager, "default")
    assert length(FlowEngine.export_definition(engine)["nodes"]) == 1
    assert {:ok, _workflow} = FlowEngine.WorkflowManager.create(manager, "Second")
    assert {:ok, %{"version" => 2}} = FlowEngine.Persistence.load(path)
  end
end
