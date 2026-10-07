defmodule FlowEngine.Persistence do
  @moduledoc "以 JSON 原子保存和读取工作流定义。"

  def save(path, definition) when is_binary(path) and is_map(definition) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp"
    backup = path <> ".bak"

    with :ok <- File.mkdir_p(directory),
         encoded <- Jason.encode!(definition, pretty: true),
         :ok <- File.write(temporary, encoded, [:binary]),
         :ok <- backup_existing(path, backup),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> decode(content)
      {:error, _reason} = error -> error
    end
  end

  def load_with_backup(path) when is_binary(path) do
    case load(path) do
      {:ok, definition} ->
        {:ok, definition, :primary}

      {:error, _} ->
        case load(path <> ".bak") do
          {:ok, definition} -> {:ok, definition, :backup}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, definition} when is_map(definition) -> {:ok, definition}
      {:ok, _other} -> {:error, :invalid_workflow_shape}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp backup_existing(path, backup) do
    if File.exists?(path), do: File.cp(path, backup), else: :ok
  end
end
