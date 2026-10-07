defmodule FlowEngine.Nodes.PassThrough do
  @moduledoc "原样转发消息的基础节点。"
  @behaviour FlowEngine.Node
  def init(config), do: {:ok, config}
  def handle_message(_port, message, state), do: {:emit, [{0, message}], state}
end
