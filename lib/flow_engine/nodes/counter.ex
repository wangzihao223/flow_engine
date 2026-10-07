defmodule FlowEngine.Nodes.Counter do
  @moduledoc "统计经过节点的消息数量并写入 payload.count。"
  @behaviour FlowEngine.Node
  alias FlowEngine.Nodes.Message

  def init(config) do
    initial = config |> value("initial_value", 0) |> number(0)
    increment = config |> value("increment", 1) |> number(1)
    {:ok, {initial, increment}}
  end

  def handle_message(_port, message, {count, increment}) do
    next_count = count + increment
    {:emit, [{0, Message.put(message, "msg.payload.count", next_count)}], {next_count, increment}}
  end

  defp value(config, key, default),
    do: Map.get(config, key, Map.get(config, String.to_atom(key), default))

  defp number(value, _default) when is_number(value), do: value

  defp number(value, default) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp number(_value, default), do: default
end
