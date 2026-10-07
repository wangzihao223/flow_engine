defmodule FlowEngine.Nodes.Message do
  @moduledoc "消息路径和类型转换工具。"

  def get(message, path, default \\ nil) do
    path
    |> to_string()
    |> String.split(".")
    |> drop_message_prefix()
    |> Enum.reduce_while({:ok, message}, fn key, {:ok, value} ->
      case map_value(value, key) do
        {:ok, child} -> {:cont, {:ok, child}}
        :missing -> {:halt, :missing}
      end
    end)
    |> case do
      {:ok, value} -> value
      :missing -> default
    end
  end

  def put(message, path, value) when is_map(message) do
    keys = path |> to_string() |> String.split(".") |> drop_message_prefix()
    put_keys(message, keys, value)
  end

  def convert(value, "num"), do: number(value)
  def convert(value, :num), do: number(value)
  def convert(value, "bool"), do: value in [true, "true", "1", 1]
  def convert(value, :bool), do: convert(value, "bool")
  def convert(value, _), do: value

  defp drop_message_prefix(["msg" | keys]), do: keys
  defp drop_message_prefix(keys), do: keys

  defp map_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:ok, Map.get(map, String.to_atom(key))}
      true -> :missing
    end
  rescue
    ArgumentError -> :missing
  end

  defp map_value(_, _), do: :missing

  defp put_keys(map, [key], value), do: Map.put(map, key, value)

  defp put_keys(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_keys(if(is_map(child), do: child, else: %{}), rest, value))
  end

  defp put_keys(map, [], _value), do: map
  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp number(value), do: value
end
