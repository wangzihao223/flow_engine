defmodule FlowEngine.Nodes.Camera do
  @moduledoc "通过 hik 的 HTTP 接口控制相机；工作流消息不携带图片字节。"
  @behaviour FlowEngine.Node

  alias FlowEngine.Adapters.HTTPJSON

  def init(config) when is_map(config) do
    serial = value(config, "serial")
    base_url = value(config, "base_url", "http://127.0.0.1:8080")
    action = value(config, "action", "trigger")
    timeout = value(config, "timeout_ms", 3_000)

    if is_binary(serial) and byte_size(serial) in 1..80 and
         not String.contains?(serial, ["/", <<0>>]) and is_binary(base_url) and
         action in ["trigger", "status"] and is_integer(timeout) and timeout in 1..60_000 do
      {:ok,
       %{
         serial: serial,
         base_url: String.trim_trailing(base_url, "/"),
         action: action,
         timeout: timeout,
         token: value(config, "token")
       }}
    else
      {:error, :invalid_camera_config}
    end
  end

  def init(_), do: {:error, :invalid_camera_config}

  def handle_message(_port, message, state) when is_map(message) do
    path = "/api/v1/cameras/" <> URI.encode(state.serial, &unreserved?/1)

    {method, url} =
      case state.action do
        "trigger" -> {:post, state.base_url <> path <> "/triggers/software"}
        "status" -> {:get, state.base_url <> path}
      end

    case HTTPJSON.request(method, url, nil, timeout: state.timeout, token: state.token) do
      {:ok, response} ->
        camera = %{"serial" => state.serial, "action" => state.action, "response" => response}
        topic = %{"service" => "HikCamera", "instance" => state.serial, "event" => "Raw"}

        output =
          message
          |> Map.put("camera", camera)
          |> Map.put_new("topic", topic)

        {:emit, [{0, output}], state}

      {:error, reason} ->
        {:error, {:camera, reason}, state}
    end
  end

  def handle_message(_port, _message, state), do: {:error, :invalid_message, state}

  defp value(config, key, default \\ nil),
    do: Map.get(config, key, Map.get(config, String.to_atom(key), default))

  defp unreserved?(char),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?-, ?_, ?., ?~]
end
