defmodule FlowEngine.DeviceNodesTest do
  use ExUnit.Case, async: false

  alias FlowEngine.Nodes.{Camera, PLC, PythonService}

  defmodule MockDeviceHTTP do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/api/v1/cameras/CAM1" do
      Plug.Conn.send_resp(conn, 200, ~s({"serial":"CAM1","connected":true}))
    end

    post "/api/v1/cameras/CAM1/triggers/software" do
      Plug.Conn.send_resp(conn, 202, "")
    end

    post "/vision" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      response =
        Jason.encode!(%{
          "request_id" => request["request_id"],
          "status" => "ok",
          "result" => %{"count" => 2}
        })

      Plug.Conn.send_resp(conn, 200, response)
    end

    post "/devices/plc1/read_point" do
      Plug.Conn.send_resp(conn, 200, ~s({"value":42}))
    end

    post "/devices/plc1/write_point" do
      Plug.Conn.send_resp(conn, 200, ~s({"result":"written"}))
    end
  end

  defmodule FakePLC do
    @behaviour FlowEngine.Adapters.PLCTransport

    def read(_connection, address, _timeout), do: {:ok, "read:" <> address}

    def write(_connection, address, value, request_id, _timeout),
      do: {:ok, {address, value, request_id}}
  end

  setup do
    previous = Application.get_env(:flow_engine, :plc_transport)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:flow_engine, :plc_transport)
      else
        Application.put_env(:flow_engine, :plc_transport, previous)
      end
    end)
  end

  test "内置设备节点已注册" do
    registry = FlowEngine.NodeRegistry.builtins()
    assert FlowEngine.NodeRegistry.resolve(registry, "CameraNode") == Camera
    assert FlowEngine.NodeRegistry.resolve(registry, "VisionNode") == PythonService
    assert FlowEngine.NodeRegistry.resolve(registry, "InferenceNode") == PythonService
    assert FlowEngine.NodeRegistry.resolve(registry, "PLCNode") == PLC
  end

  test "相机配置验证，Python 服务要求帧引用" do
    assert {:error, :invalid_camera_config} = Camera.init(%{"serial" => "bad/serial"})

    assert {:ok, python} =
             PythonService.init(%{"url" => "http://127.0.0.1:1/vision", "operation" => "detect"})

    assert {:error, {:python_service, :missing_frame_reference}, ^python} =
             PythonService.handle_message(0, %{"image" => <<1, 2, 3>>}, python)
  end

  test "PLC 写入必须有幂等请求 ID，未配置传输时显式失败" do
    assert {:ok, state} =
             PLC.init(%{"action" => "write", "connection" => %{"id" => "a"}, "address" => "D1"})

    assert {:error, {:plc, :transport_not_configured}, ^state} =
             PLC.handle_message(0, %{"request_id" => "req-1", "value" => 1}, state)

    Application.put_env(:flow_engine, :plc_transport, FakePLC)

    assert {:error, {:plc, :missing_request_id}, ^state} =
             PLC.handle_message(0, %{"value" => 1}, state)

    assert {:error, {:plc, :missing_value}, ^state} =
             PLC.handle_message(0, %{"request_id" => "req-1"}, state)

    assert {:emit, [{0, %{"plc" => %{"value" => {"D1", 1, "req-1"}}}}], ^state} =
             PLC.handle_message(0, %{"request_id" => "req-1", "value" => 1}, state)
  end

  test "PLC 表单配置转换为连接和点位，并兼容旧配置" do
    config = %{
      "action" => "read",
      "base_url" => "http://127.0.0.1:4001",
      "device_id" => "plc1",
      "token" => "secret",
      "db" => 1,
      "offset" => 2,
      "point_type" => "bool",
      "bit" => 3,
      "size" => 1
    }

    assert {:ok, state} = PLC.init(config)

    assert state.connection == %{
             "base_url" => config["base_url"],
             "device_id" => "plc1",
             "token" => "secret"
           }

    assert Jason.decode!(state.address) == %{
             "db" => 1,
             "offset" => 2,
             "type" => "bool",
             "bit" => 3
           }

    assert {:ok, string_state} = PLC.init(%{config | "point_type" => "string", "size" => 12})

    assert Jason.decode!(string_state.address) == %{
             "db" => 1,
             "offset" => 2,
             "type" => "string",
             "size" => 12
           }

    assert {:error, :invalid_plc_config} = PLC.init(%{config | "device_id" => "bad/id"})
    assert {:error, :invalid_plc_config} = PLC.init(%{config | "bit" => 8})
    assert {:error, :invalid_plc_config} = PLC.init(%{config | "db" => -1})
    assert {:error, :invalid_plc_config} = PLC.init(%{config | "base_url" => "not-a-url"})

    assert {:ok, legacy} = PLC.init(%{"action" => "read", "connection" => %{}, "address" => "D1"})
    assert legacy.address == "D1"
  end

  test "设备节点通过真实 HTTP 请求传递控制和元数据" do
    {:ok, server} =
      Bandit.start_link(plug: MockDeviceHTTP, port: 0, ip: {127, 0, 0, 1}, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"

    {:ok, camera} = Camera.init(%{"serial" => "CAM1", "base_url" => base_url})

    assert {:emit, [{0, %{"camera" => %{"response" => %{}}, "topic" => %{"event" => "Raw"}}}],
            ^camera} =
             Camera.handle_message(0, %{}, camera)

    {:ok, vision} = PythonService.init(%{"url" => base_url <> "/vision", "operation" => "detect"})

    assert {:emit, [{0, %{"result" => %{"count" => 2}}}], ^vision} =
             PythonService.handle_message(0, %{"frame_id" => %{"sequence" => 1}}, vision)

    connection = %{"base_url" => base_url, "device_id" => "plc1"}
    point = ~s({"db":1,"offset":2,"type":"int16"})
    Application.put_env(:flow_engine, :plc_transport, FlowEngine.Adapters.PLCServerHTTP)
    {:ok, plc} = PLC.init(%{"action" => "read", "connection" => connection, "address" => point})
    assert {:emit, [{0, %{"plc" => %{"value" => 42}}}], ^plc} = PLC.handle_message(0, %{}, plc)

    {:ok, write} =
      PLC.init(%{"action" => "write", "connection" => connection, "address" => point})

    assert {:emit, [{0, %{"plc" => %{"value" => 7}}}], ^write} =
             PLC.handle_message(0, %{"request_id" => "write-1", "value" => 7}, write)

    GenServer.stop(server)
  end
end
