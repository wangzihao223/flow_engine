defmodule FlowEngine.NodeRegistry do
  @moduledoc "把工作流节点类型名称映射到 Elixir 节点模块。"

  defstruct types: %{}

  def new(types \\ %{}) when is_map(types), do: %__MODULE__{types: types}

  def register(%__MODULE__{} = registry, type, module)
      when (is_binary(type) or is_atom(type)) and is_atom(module) do
    %{registry | types: Map.put(registry.types, type, module)}
  end

  def register!(registry, type, module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :init, 1) and function_exported?(module, :handle_message, 3) do
      register(registry, type, module)
    else
      raise ArgumentError, "无效的工作流节点模块：#{inspect(module)}"
    end
  end

  def resolve(%__MODULE__{types: types}, type),
    do: Map.get(types, type) || Map.get(types, to_string(type))

  def list(%__MODULE__{types: types}), do: types

  def builtins do
    new()
    |> register!("PassThroughNode", FlowEngine.Nodes.PassThrough)
    |> register!("ChangeNode", FlowEngine.Nodes.Change)
    |> register!("SwitchNode", FlowEngine.Nodes.Switch)
    |> register!("CounterNode", FlowEngine.Nodes.Counter)
    |> register!("CameraNode", FlowEngine.Nodes.Camera)
    |> register!("VisionNode", FlowEngine.Nodes.PythonService)
    |> register!("InferenceNode", FlowEngine.Nodes.PythonService)
    |> register!("PLCNode", FlowEngine.Nodes.PLC)
  end
end
