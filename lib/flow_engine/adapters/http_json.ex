defmodule FlowEngine.Adapters.HTTPJSON do
  @moduledoc "供相机及外部服务使用的 JSON HTTP 客户端。"

  def request(method, url, body \\ nil, opts \\ [])

  def request(method, url, body, opts) when method in [:get, :post] do
    timeout = Keyword.get(opts, :timeout, 3_000)
    token = Keyword.get(opts, :token)

    with :ok <- validate_url(url),
         :ok <- validate_timeout(timeout),
         {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      headers =
        if is_binary(token) and token != "" do
          [{~c"Authorization", ~c"Bearer " ++ to_charlist(token)}]
        else
          []
        end

      request =
        if method == :get do
          {to_charlist(url), headers}
        else
          {to_charlist(url), headers, ~c"application/json", Jason.encode!(body || %{})}
        end

      case :httpc.request(method, request, [timeout: timeout, connect_timeout: timeout],
             body_format: :binary
           ) do
        {:ok, response} -> decode(response)
        {:error, reason} -> {:error, {:transport, reason}}
      end
    end
  end

  def request(_, _, _, _), do: {:error, :invalid_request}

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, :invalid_url}
    end
  end

  defp validate_url(_), do: {:error, :invalid_url}
  defp validate_timeout(timeout) when is_integer(timeout) and timeout in 1..60_000, do: :ok
  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp decode({{_, status, _}, _headers, body}) when status in 200..299 do
    case body do
      "" -> {:ok, %{}}
      _ -> Jason.decode(body)
    end
  end

  defp decode({{_, status, _}, _headers, body}) do
    detail =
      case Jason.decode(body) do
        {:ok, %{"error" => error}} -> error
        _ -> String.slice(body, 0, 256)
      end

    {:error, {:http, status, detail}}
  end
end
