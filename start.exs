port = System.get_env("FLOW_ENGINE_PORT", "4000") |> String.to_integer()

workflow_file =
  System.get_env(
    "FLOW_ENGINE_WORKFLOW_FILE",
    Path.join(__DIR__, "data/workflow.json")
  )

{:ok, engine} = FlowEngine.start_link()

Application.put_env(:flow_engine, :plc_transport, FlowEngine.Adapters.PLCServerHTTP)

{:ok, _server} =
  FlowEngine.HttpServer.start_link(
    engine: engine,
    port: port,
    persistence_path: workflow_file
  )

IO.puts("Flow Engine 已启动：http://127.0.0.1:#{port}/")
IO.puts("工作流文件：#{workflow_file}")

Process.sleep(:infinity)
