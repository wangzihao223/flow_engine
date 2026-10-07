defmodule FlowEngine.Checkpoint do
  @moduledoc """
  工作流运行态 checkpoint 的保存与恢复。

  checkpoint 使用 Erlang term 二进制保存，因此可以保留节点的可序列化状态、模块和配置。
  文件采用临时文件加原子重命名，进程异常时不会覆盖已有 checkpoint。
  """

  @magic "FLOW_ENGINE_CHECKPOINT_V1"

  @doc "导出当前引擎的运行态快照。"
  def snapshot(engine), do: FlowEngine.checkpoint_snapshot(engine)

  @doc "把当前运行态保存到文件。"
  def save(engine, path) when is_binary(path) do
    snapshot = snapshot(engine)
    directory = Path.dirname(path)
    temporary = path <> ".tmp"
    payload = :erlang.term_to_binary({@magic, snapshot}, [:compressed])

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary, payload, [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "从文件读取并恢复运行态。"
  def load(engine, path) when is_binary(path) do
    with {:ok, payload} <- File.read(path),
         {:ok, snapshot} <- decode(payload),
         :ok <- FlowEngine.restore_checkpoint(engine, snapshot) do
      :ok
    end
  end

  defp decode(payload) do
    try do
      case :erlang.binary_to_term(payload, [:safe]) do
        {@magic, snapshot} when is_map(snapshot) -> {:ok, snapshot}
        _ -> {:error, :invalid_checkpoint}
      end
    rescue
      ArgumentError -> {:error, :invalid_checkpoint}
    end
  end
end
