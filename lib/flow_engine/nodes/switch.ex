defmodule FlowEngine.Nodes.Switch do
  @moduledoc "根据规则把消息发送到不同输出端口。"
  @behaviour FlowEngine.Node
  alias FlowEngine.Nodes.Message

  def init(config), do: {:ok, config}

  def handle_message(_port, message, state) do
    property = Map.get(state, "property", Map.get(state, :property, "msg.payload"))
    value = Message.get(message, property)
    rules = Map.get(state, "rules", Map.get(state, :rules, []))

    outputs =
      rules |> Enum.with_index() |> Enum.filter(fn {rule, _index} -> match_rule?(rule, value) end)

    selected =
      if Map.get(state, "checkall", Map.get(state, :checkall, false)),
        do: outputs,
        else: Enum.take(outputs, 1)

    {:emit, Enum.map(selected, fn {_rule, index} -> {index, message} end), state}
  end

  defp match_rule?(rule, value) do
    operator = Map.get(rule, "operator", Map.get(rule, :operator))
    if operator in ["else", :else], do: true, else: evaluate(operator, rule, value)
  end

  defp evaluate(operator, rule, value) do
    expected =
      Message.convert(
        Map.get(rule, "value", Map.get(rule, :value)),
        Map.get(rule, "valueType", Map.get(rule, :value_type, "str"))
      )

    case operator do
      "eq" -> value == expected
      :eq -> value == expected
      "neq" -> value != expected
      "gte" -> comparable(value, expected, &>=/2)
      "gt" -> comparable(value, expected, &>/2)
      "lte" -> comparable(value, expected, &<=/2)
      "lt" -> comparable(value, expected, &</2)
      _ -> false
    end
  end

  defp comparable(left, right, fun) when is_number(left) and is_number(right),
    do: fun.(left, right)

  defp comparable(_, _, _), do: false
end
