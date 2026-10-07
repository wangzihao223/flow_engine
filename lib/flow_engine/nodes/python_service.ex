defmodule FlowEngine.Nodes.PythonService do
  @moduledoc "向视觉或推理 HTTP 服务发送帧描述，不传图片内容。"
  @behaviour FlowEngine.Node

  alias FlowEngine.Adapters.HTTPJSON

  def init(config) when is_map(config) do
    url = value(config, "url")
    operation = value(config, "operation")
    timeout = value(config, "timeout_ms", 3_000)

    if is_binary(url) and is_binary(operation) and operation != "" and
         is_integer(timeout) and timeout in 1..60_000 do
      {:ok, %{url: url, operation: operation, timeout: timeout, token: value(config, "token")}}
    else
      {:error, :invalid_python_service_config}
    end
  end

  def init(_), do: {:error, :invalid_python_service_config}

  def handle_message(_port, message, state) when is_map(message) do
    metadata =
      Map.take(message, ["frame_id", "topic", "camera_id", "workflow_id", "node_id", "request_id"])

    if Map.has_key?(metadata, "frame_id") or Map.has_key?(metadata, "topic") do
      request_id =
        Map.get(metadata, "request_id") ||
          Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      request =
        metadata
        |> Map.put("request_id", request_id)
        |> Map.put("operation", state.operation)
        |> Map.put("deadline_ms", System.system_time(:millisecond) + state.timeout)

      case HTTPJSON.request(:post, state.url, request, timeout: state.timeout, token: state.token) do
        {:ok, %{"request_id" => ^request_id, "status" => "ok", "result" => result}} ->
          {:emit, [{0, Map.put(message, "result", result)}], state}

        {:ok, %{"request_id" => ^request_id, "status" => "error"} = response} ->
          {:error, {:python_service, Map.get(response, "error", :remote_error)}, state}

        {:ok, _} ->
          {:error, {:python_service, :invalid_response}, state}

        {:error, reason} ->
          {:error, {:python_service, reason}, state}
      end
    else
      {:error, {:python_service, :missing_frame_reference}, state}
    end
  end

  def handle_message(_port, _message, state), do: {:error, :invalid_message, state}

  defp value(config, key, default \\ nil),
    do: Map.get(config, key, Map.get(config, String.to_atom(key), default))
end
