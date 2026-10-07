defmodule FlowEngine.Nodes.Change do
  @moduledoc "按 rules 配置修改消息字段。"
  @behaviour FlowEngine.Node
  alias FlowEngine.Nodes.Message

  def init(config), do: {:ok, config}

  def handle_message(_port, message, state) do
    changed =
      Enum.reduce(Map.get(state, "rules", Map.get(state, :rules, [])), message, &apply_rule/2)

    {:emit, [{0, changed}], state}
  end

  defp apply_rule(rule, message) do
    type = Map.get(rule, "type", Map.get(rule, :type))

    if type in ["set", :set] do
      path = Map.get(rule, "path", Map.get(rule, :path, "msg.payload"))
      value = Map.get(rule, "value", Map.get(rule, :value))
      value_type = Map.get(rule, "valueType", Map.get(rule, :value_type, "str"))
      Message.put(message, path, Message.convert(value, value_type))
    else
      message
    end
  end
end
