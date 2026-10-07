defmodule FlowEngine.RealtimeHttpTest do
  use ExUnit.Case, async: false

  test "Bandit 的 SSE 长连接持续收到新事件" do
    {:ok, engine} = FlowEngine.start_link()

    {:ok, server} =
      Bandit.start_link(
        plug: {FlowEngine.HttpRouter, [engine: engine]},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /api/events/stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert recv_until(socket, ": connected") =~ "text/event-stream"

    send(engine, {:node_event, "camera-1", :error, :disconnected})
    stream = recv_until(socket, "disconnected")
    assert stream =~ "event: runtime"
    assert stream =~ "camera-1"

    :gen_tcp.close(socket)
    Process.unlink(server)
    Process.exit(server, :shutdown)
  end

  defp recv_until(socket, needle, buffer \\ "", attempts \\ 10)
  defp recv_until(_socket, _needle, _buffer, 0), do: flunk("SSE event did not arrive")

  defp recv_until(socket, needle, buffer, attempts) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        received = buffer <> data

        if String.contains?(received, needle),
          do: received,
          else: recv_until(socket, needle, received, attempts - 1)

      {:error, reason} ->
        flunk("SSE connection failed: #{inspect(reason)}")
    end
  end
end
