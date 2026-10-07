defmodule FlowEngine.HttpServer do
  @moduledoc "使用 Bandit 启动 Flow Engine HTTP 服务。"

  def start_link(opts) do
    engine = Keyword.fetch!(opts, :engine)
    registry = Keyword.get(opts, :registry, FlowEngine.NodeRegistry.builtins())
    port = Keyword.get(opts, :port, 4000)
    persistence_path = Keyword.get(opts, :persistence_path)

    {:ok, manager} =
      FlowEngine.WorkflowManager.start_link(
        engine: engine,
        registry: registry,
        persistence_path: persistence_path
      )

    Bandit.start_link(
      plug:
        {FlowEngine.HttpRouter,
         [
           engine: engine,
           registry: registry,
           persistence_path: persistence_path,
           manager: manager
         ]},
      scheme: :http,
      port: port
    )
  end
end
