defmodule FlowEngine.Nodes.PLC do
  @moduledoc "通过可注入的 PLC 传输模块读写，写入必须有幂等请求 ID。"
  @behaviour FlowEngine.Node

  @point_types ~w(bool int16 uint16 int32 uint32 float32 string bytes)

  def init(config) when is_map(config) do
    action = value(config, "action")
    timeout = value(config, "timeout_ms", 3_000)

    with true <- action in ["read", "write"] and is_integer(timeout) and timeout in 1..60_000,
         {:ok, connection, address} <- connection_and_address(config) do
      {:ok, %{action: action, connection: connection, address: address, timeout: timeout}}
    else
      _ -> {:error, :invalid_plc_config}
    end
  end

  def init(_), do: {:error, :invalid_plc_config}

  def handle_message(_port, message, state) when is_map(message) do
    transport = Application.get_env(:flow_engine, :plc_transport)

    if is_atom(transport) and not is_nil(transport), do: Code.ensure_loaded(transport)

    cond do
      not is_atom(transport) or is_nil(transport) ->
        {:error, {:plc, :transport_not_configured}, state}

      state.action == "read" and function_exported?(transport, :read, 3) ->
        result(transport.read(state.connection, state.address, state.timeout), message, state)

      state.action == "write" and not valid_request_id?(message) ->
        {:error, {:plc, :missing_request_id}, state}

      state.action == "write" and not Map.has_key?(message, "value") ->
        {:error, {:plc, :missing_value}, state}

      state.action == "write" and function_exported?(transport, :write, 5) ->
        result(
          transport.write(
            state.connection,
            state.address,
            Map.get(message, "value"),
            Map.fetch!(message, "request_id"),
            state.timeout
          ),
          message,
          state
        )

      true ->
        {:error, {:plc, :invalid_transport}, state}
    end
  rescue
    error -> {:error, {:plc, {:transport_exception, Exception.message(error)}}, state}
  catch
    :exit, reason -> {:error, {:plc, {:transport_exit, reason}}, state}
  end

  def handle_message(_port, _message, state), do: {:error, :invalid_message, state}

  defp result({:ok, value}, message, state),
    do:
      {:emit, [{0, Map.put(message, "plc", %{"address" => state.address, "value" => value})}],
       state}

  defp result({:error, reason}, _message, state), do: {:error, {:plc, reason}, state}
  defp result(_, _message, state), do: {:error, {:plc, :invalid_response}, state}

  defp valid_request_id?(message),
    do: is_binary(Map.get(message, "request_id")) and Map.get(message, "request_id") != ""

  defp connection_and_address(config) do
    if Enum.any?(~w(base_url device_id db offset point_type), &has_value?(config, &1)) do
      form_connection_and_address(config)
    else
      connection = value(config, "connection")
      address = value(config, "address")

      if is_map(connection) and is_binary(address) and address != "" do
        {:ok, connection, address}
      else
        {:error, :invalid_plc_config}
      end
    end
  end

  defp form_connection_and_address(config) do
    base_url = value(config, "base_url")
    device_id = value(config, "device_id")
    token = value(config, "token", "")
    db = value(config, "db")
    offset = value(config, "offset")
    point_type = value(config, "point_type")
    uri = if is_binary(base_url), do: URI.parse(base_url), else: nil

    if is_struct(uri, URI) and uri.scheme in ["http", "https"] and is_binary(uri.host) and
         is_binary(device_id) and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, device_id) and
         (is_nil(token) or is_binary(token)) and is_integer(db) and db >= 0 and
         is_integer(offset) and offset >= 0 and point_type in @point_types do
      with {:ok, point} <-
             add_type_fields(%{"db" => db, "offset" => offset, "type" => point_type}, config) do
        connection = %{"base_url" => base_url, "device_id" => device_id}

        connection =
          if token in [nil, ""], do: connection, else: Map.put(connection, "token", token)

        {:ok, connection, Jason.encode!(point)}
      end
    else
      {:error, :invalid_plc_config}
    end
  end

  defp add_type_fields(%{"type" => "bool"} = point, config) do
    bit = value(config, "bit", 0)

    if is_integer(bit) and bit in 0..7,
      do: {:ok, Map.put(point, "bit", bit)},
      else: {:error, :invalid_plc_config}
  end

  defp add_type_fields(%{"type" => type} = point, config) when type in ["string", "bytes"] do
    size = value(config, "size", 1)

    if is_integer(size) and size in 1..65_535,
      do: {:ok, Map.put(point, "size", size)},
      else: {:error, :invalid_plc_config}
  end

  defp add_type_fields(point, _config), do: {:ok, point}

  defp has_value?(config, key),
    do: Map.has_key?(config, key) or Map.has_key?(config, String.to_atom(key))

  defp value(config, key, default \\ nil),
    do: Map.get(config, key, Map.get(config, String.to_atom(key), default))
end
