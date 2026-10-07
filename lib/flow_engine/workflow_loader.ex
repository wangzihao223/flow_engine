defmodule FlowEngine.WorkflowLoader do
  @moduledoc "加载现有的 nodes/connections 工作流格式。"

  def load(engine, workflow, resolver) when is_function(resolver, 1) do
    nodes = field(workflow, :nodes, :missing)
    connections = field(workflow, :connections, :missing)

    with :ok <- validate(workflow, resolver),
         :ok <- add_nodes(engine, nodes, resolver),
         :ok <- add_connections(engine, connections) do
      :ok
    end
  end

  def load(engine, workflow, %FlowEngine.NodeRegistry{} = registry) do
    load(engine, workflow, &FlowEngine.NodeRegistry.resolve(registry, &1))
  end

  def validate(workflow, %FlowEngine.NodeRegistry{} = registry) do
    validate(workflow, &FlowEngine.NodeRegistry.resolve(registry, &1))
  end

  def validate(workflow, resolver) when is_map(workflow) and is_function(resolver, 1) do
    nodes = field(workflow, :nodes, :missing)
    connections = field(workflow, :connections, :missing)

    if is_list(nodes) and is_list(connections) and
         Enum.all?(nodes, &is_map/1) and Enum.all?(connections, &is_map/1) do
      with :ok <- validate_nodes(nodes, resolver),
           :ok <- validate_connections(connections, nodes) do
        :ok
      end
    else
      {:error, :invalid_workflow_shape}
    end
  end

  def validate(_workflow, _resolver), do: {:error, :invalid_workflow_shape}

  defp validate_nodes(nodes, resolver) do
    ids = Enum.map(nodes, &field(&1, :id))

    cond do
      Enum.any?(ids, &is_nil/1) ->
        {:error, :node_id_missing}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_node_id}

      Enum.any?(nodes, fn node -> not is_map(field(node, :config, %{})) end) ->
        {:error, :invalid_node_config}

      Enum.any?(nodes, fn node -> is_nil(resolve(resolver, field(node, :type))) end) ->
        {:error, :unknown_node_type}

      true ->
        :ok
    end
  end

  defp validate_connections(connections, nodes) do
    ids = MapSet.new(Enum.map(nodes, &field(&1, :id)))

    if Enum.all?(connections, fn connection ->
         MapSet.member?(ids, field(connection, :source)) and
           MapSet.member?(ids, field(connection, :target))
       end), do: :ok, else: {:error, :connection_node_missing}
  end

  defp add_nodes(engine, nodes, resolver) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      id = field(node, :id)
      config = field(node, :config, %{})

      metadata = %{
        type: field(node, :type),
        name: field(node, :name),
        enabled: field(node, :enabled, true),
        x: field(node, :x),
        y: field(node, :y)
      }

      case FlowEngine.add_node(
             engine,
             id,
             resolve(resolver, field(node, :type)),
             config,
             metadata
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:add_node, id, reason}}}
      end
    end)
  end

  defp add_connections(engine, connections) do
    Enum.reduce_while(connections, :ok, fn connection, :ok ->
      result =
        FlowEngine.connect(
          engine,
          field(connection, :source),
          field(connection, :source_output, 0),
          field(connection, :target),
          field(connection, :target_input, 0)
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:connect, reason}}}
      end
    end)
  end

  defp resolve(resolver, type) do
    case resolver.(type) do
      {:ok, module} when is_atom(module) -> module
      module when is_atom(module) -> module
      _ -> nil
    end
  end

  defp field(map, key, default \\ nil) do
    camel_key =
      key
      |> Atom.to_string()
      |> String.split("_")
      |> then(fn [head | tail] -> head <> Enum.map_join(tail, "", &String.capitalize/1) end)

    Map.get(map, key, Map.get(map, Atom.to_string(key), Map.get(map, camel_key, default)))
  end
end
