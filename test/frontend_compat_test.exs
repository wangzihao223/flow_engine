defmodule FlowEngine.FrontendCompatTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  defmodule Node do
    @behaviour FlowEngine.Node
    def init(config), do: {:ok, config}
    def handle_message(_port, _message, state), do: {:ok, state}
  end

  defp opts(engine), do: [engine: engine, registry: FlowEngine.NodeRegistry.builtins()]

  test "兼容旧前端的节点启用、位置、统计和动作接口" do
    {:ok, engine} = FlowEngine.start_link()
    :ok = FlowEngine.add_node(engine, "node-1", Node, %{}, %{type: "PassThroughNode"})

    enabled = conn(:get, "/api/nodes/node-1/enabled") |> FlowEngine.HttpRouter.call(opts(engine))
    assert enabled.status == 200
    assert Jason.decode!(enabled.resp_body)["enabled"] == true

    body = Jason.encode!(%{"enabled" => false})
    disabled =
      conn(:post, "/api/nodes/node-1/enabled", body)
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(opts(engine))

    assert disabled.status == 200
    assert Jason.decode!(disabled.resp_body)["enabled"] == false

    position =
      conn(:put, "/api/nodes/node-1/position", Jason.encode!(%{"x" => 12, "y" => 34}))
      |> put_req_header("content-type", "application/json")
      |> FlowEngine.HttpRouter.call(opts(engine))

    assert position.status == 200
    assert Jason.decode!(position.resp_body)["x"] == 12

    stats = conn(:get, "/api/nodes/node-1/stats") |> FlowEngine.HttpRouter.call(opts(engine))
    assert stats.status == 200
    assert Jason.decode!(stats.resp_body)["success"] == true

    action = conn(:post, "/api/nodes/node-1/inject") |> FlowEngine.HttpRouter.call(opts(engine))
    assert action.status == 200
    assert Jason.decode!(action.resp_body)["action"] == "inject"
  end

  test "兼容旧前端的工作流重启接口" do
    {:ok, engine} = FlowEngine.start_link()
    :ok = FlowEngine.start_workflow(engine)

    response = conn(:post, "/api/workflow/restart") |> FlowEngine.HttpRouter.call(opts(engine))
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["restarted"] == 1
  end
end
