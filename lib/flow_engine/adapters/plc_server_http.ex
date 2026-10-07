defmodule FlowEngine.Adapters.PLCServerHTTP do
  @moduledoc "通过独立 plc_server 的 HTTP API 读写点位。"
  @behaviour FlowEngine.Adapters.PLCTransport

  alias FlowEngine.Adapters.HTTPJSON

  @point_types ~w(bool int16 uint16 int32 uint32 float32 string bytes)

  @impl true
  def read(connection, address, timeout) do
    with {:ok, url, token} <- endpoint(connection, "read_point"),
         {:ok, point} <- point(address),
         {:ok, response} <- HTTPJSON.request(:post, url, point, timeout: timeout, token: token),
         {:ok, value} <- Map.fetch(response, "value") do
      {:ok, value}
    else
      :error -> {:error, :invalid_response}
      error -> error
    end
  end

  @impl true
  def write(connection, address, value, request_id, timeout) do
    with {:ok, url, token} <- endpoint(connection, "write_point"),
         {:ok, point} <- point(address),
         {:ok, %{"result" => "written"}} <-
           HTTPJSON.request(
             :post,
             url,
             Map.merge(point, %{"value" => value, "request_id" => request_id}),
             timeout: timeout,
             token: token
           ) do
      {:ok, value}
    else
      {:ok, _response} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp endpoint(connection, action) when is_map(connection) do
    base_url = Map.get(connection, "base_url", Map.get(connection, :base_url))
    device_id = Map.get(connection, "device_id", Map.get(connection, :device_id))
    token = Map.get(connection, "token", Map.get(connection, :token))

    if is_binary(base_url) and is_binary(device_id) and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, device_id) do
      {:ok, String.trim_trailing(base_url, "/") <> "/devices/" <> device_id <> "/" <> action,
       token}
    else
      {:error, :invalid_connection}
    end
  end

  defp endpoint(_connection, _action), do: {:error, :invalid_connection}

  defp point(address) when is_binary(address) do
    with {:ok, %{"db" => db, "offset" => offset, "type" => type} = point} <- Jason.decode(address),
         true <- is_integer(db) and db >= 0 and is_integer(offset) and offset >= 0,
         true <- type in @point_types,
         true <- valid_optional_fields?(point) do
      {:ok, Map.take(point, ["db", "offset", "type", "bit", "size"])}
    else
      _ -> {:error, :invalid_address}
    end
  end

  defp point(_address), do: {:error, :invalid_address}

  defp valid_optional_fields?(point) do
    valid_integer?(point, "bit", 0, 7) and valid_integer?(point, "size", 1, 65_535)
  end

  defp valid_integer?(point, key, minimum, maximum) do
    case Map.fetch(point, key) do
      :error -> true
      {:ok, value} -> is_integer(value) and value in minimum..maximum
    end
  end
end
