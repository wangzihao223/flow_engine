defmodule FlowEngine.WorkflowManager do
  @moduledoc "管理多个独立运行的工作流及其持久化定义。"

  use GenServer

  alias FlowEngine.Persistence

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def list(server), do: GenServer.call(server, :list)
  def active(server), do: GenServer.call(server, :active)
  def engine(server, id), do: GenServer.call(server, {:engine, id})
  def create(server, name), do: GenServer.call(server, {:create, name})
  def update(server, id, attrs), do: GenServer.call(server, {:update, id, attrs})
  def delete(server, id), do: GenServer.call(server, {:delete, id})
  def activate(server, id), do: GenServer.call(server, {:activate, id})
  def deploy(server, id, definition), do: GenServer.call(server, {:deploy, id, definition})
  def persist(server), do: GenServer.call(server, :persist)
  def start_all(server), do: GenServer.call(server, :start_all)
  def stop_all(server), do: GenServer.call(server, :stop_all)
  def restart_all(server), do: GenServer.call(server, :restart_all)
  def start(server, id), do: GenServer.call(server, {:start, id})
  def stop(server, id), do: GenServer.call(server, {:stop, id})

  @impl true
  def init(opts) do
    engine = Keyword.fetch!(opts, :engine)

    state = %{
      workflows: %{
        "default" => %{id: "default", name: "Default Workflow", enabled: true, engine: engine}
      },
      active: "default",
      registry: Keyword.get(opts, :registry, FlowEngine.NodeRegistry.builtins()),
      path: Keyword.get(opts, :persistence_path)
    }

    restored = restore(state)

    Enum.each(restored.workflows, fn {_id, workflow} ->
      if workflow.enabled, do: FlowEngine.start_workflow(workflow.engine)
    end)

    {:ok, restored}
  end

  @impl true
  def handle_call(:list, _from, state) do
    workflows =
      state.workflows
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&summary(&1, state.active))

    {:reply, workflows, state}
  end

  def handle_call(:active, _from, state),
    do: {:reply, summary(state.workflows[state.active], state.active), state}

  def handle_call({:engine, id}, _from, state) do
    case Map.get(state.workflows, id || state.active) do
      nil -> {:reply, {:error, :not_found}, state}
      workflow -> {:reply, {:ok, workflow.engine}, state}
    end
  end

  def handle_call({:create, name}, _from, state) do
    name = if is_binary(name), do: String.trim(name), else: ""

    if name == "" do
      {:reply, {:error, :invalid_name}, state}
    else
      id = "workflow-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      {:ok, engine} = FlowEngine.start_link()
      workflow = %{id: id, name: name, enabled: true, engine: engine}
      next = put_in(state.workflows[id], workflow)

      case persist_state(next) do
        :ok ->
          FlowEngine.start_workflow(engine)
          {:reply, {:ok, summary(workflow, state.active)}, next}

        {:error, reason} ->
          GenServer.stop(engine)
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case Map.get(state.workflows, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      workflow ->
        with {:ok, updated} <- update_fields(workflow, attrs) do
          next = put_in(state.workflows[id], updated)

          case persist_state(next) do
            :ok ->
              if updated.enabled,
                do: FlowEngine.start_workflow(updated.engine),
                else: FlowEngine.stop_workflow(updated.engine)

              {:reply, {:ok, summary(updated, state.active)}, next}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:delete, id}, _from, state) do
    cond do
      not Map.has_key?(state.workflows, id) ->
        {:reply, {:error, :not_found}, state}

      map_size(state.workflows) == 1 ->
        {:reply, {:error, :last_workflow}, state}

      true ->
        {removed, remaining} = Map.pop(state.workflows, id)

        active =
          if state.active == id,
            do: remaining |> Map.keys() |> Enum.sort() |> hd(),
            else: state.active

        next = %{state | workflows: remaining, active: active}

        case persist_state(next) do
          :ok ->
            GenServer.stop(removed.engine)
            {:reply, {:ok, active}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:activate, id}, _from, state) do
    if Map.has_key?(state.workflows, id) do
      next = %{state | active: id}

      case persist_state(next) do
        :ok -> {:reply, {:ok, summary(next.workflows[id], id)}, next}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:deploy, id, definition}, _from, state) do
    case Map.get(state.workflows, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      workflow ->
        snapshot = FlowEngine.checkpoint_snapshot(workflow.engine)

        result =
          with :ok <- FlowEngine.replace_definition(workflow.engine, definition, state.registry),
               :ok <- persist_state(state) do
            if workflow.enabled,
              do: FlowEngine.start_workflow(workflow.engine),
              else: FlowEngine.stop_workflow(workflow.engine)

            {:ok, FlowEngine.export_definition(workflow.engine)}
          end

        case result do
          {:ok, _definition} ->
            {:reply, result, state}

          {:error, reason} ->
            case FlowEngine.restore_checkpoint(workflow.engine, snapshot) do
              :ok ->
                {:reply, {:error, reason}, state}

              {:error, restore_reason} ->
                {:reply, {:error, {:rollback_failed, reason, restore_reason}}, state}
            end
        end
    end
  end

  def handle_call(:persist, _from, state), do: {:reply, persist_state(state), state}

  def handle_call(command, _from, state) when command in [:start_all, :stop_all, :restart_all] do
    Enum.each(state.workflows, fn {_id, workflow} ->
      case command do
        :stop_all ->
          FlowEngine.stop_workflow(workflow.engine)

        :start_all ->
          if workflow.enabled, do: FlowEngine.start_workflow(workflow.engine)

        :restart_all ->
          FlowEngine.stop_workflow(workflow.engine)
          if workflow.enabled, do: FlowEngine.start_workflow(workflow.engine)
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call({command, id}, _from, state) when command in [:start, :stop] do
    case Map.get(state.workflows, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      workflow ->
        result =
          if command == :start and workflow.enabled,
            do: FlowEngine.start_workflow(workflow.engine),
            else: FlowEngine.stop_workflow(workflow.engine)

        {:reply, result, state}
    end
  end

  defp summary(workflow, active) do
    status = FlowEngine.status(workflow.engine)

    %{
      id: workflow.id,
      name: workflow.name,
      enabled: workflow.enabled,
      nodeCount: map_size(status.nodes),
      running: status.status == :running,
      active: workflow.id == active
    }
  end

  defp update_fields(workflow, attrs) when is_map(attrs) do
    name = Map.get(attrs, "name", workflow.name)
    enabled = Map.get(attrs, "enabled", workflow.enabled)

    if is_binary(name) and String.trim(name) != "" and is_boolean(enabled) do
      {:ok, %{workflow | name: String.trim(name), enabled: enabled}}
    else
      {:error, :invalid_workflow_metadata}
    end
  end

  defp update_fields(_workflow, _attrs), do: {:error, :invalid_workflow_metadata}

  defp persist_state(%{path: nil}), do: {:error, :persistence_path_not_configured}

  defp persist_state(state) do
    workflows =
      state.workflows
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn workflow ->
        %{
          "id" => workflow.id,
          "name" => workflow.name,
          "enabled" => workflow.enabled,
          "definition" => FlowEngine.export_definition(workflow.engine)
        }
      end)

    Persistence.save(state.path, %{
      "version" => 2,
      "activeWorkflow" => state.active,
      "workflows" => workflows
    })
  end

  defp restore(%{path: nil} = state), do: state

  defp restore(state) do
    case Persistence.load_with_backup(state.path) do
      {:ok, %{"workflows" => workflows} = data, _source}
      when is_list(workflows) and workflows != [] ->
        restore_many(state, workflows, Map.get(data, "activeWorkflow"))

      {:ok, %{"nodes" => _, "connections" => _} = definition, _source} ->
        case FlowEngine.replace_definition(
               state.workflows["default"].engine,
               definition,
               state.registry
             ) do
          :ok ->
            state

          {:error, reason} ->
            warn_restore(reason)
            state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        warn_restore(reason)
        state

      _ ->
        state
    end
  end

  defp restore_many(state, workflows, active) do
    ids = Enum.map(workflows, fn workflow -> if is_map(workflow), do: Map.get(workflow, "id") end)

    if Enum.any?(workflows, fn workflow ->
         not is_map(workflow) or not is_binary(Map.get(workflow, "id")) or
           not is_binary(Map.get(workflow, "name")) or
           not is_boolean(Map.get(workflow, "enabled")) or
           not is_map(Map.get(workflow, "definition"))
       end) or length(ids) != length(Enum.uniq(ids)) do
      warn_restore(:invalid_workflow_store)
      state
    else
      initial = %{state | workflows: %{}, active: active}

      restored =
        Enum.with_index(workflows)
        |> Enum.reduce(initial, fn {data, index}, acc ->
          id = Map.get(data, "id")

          engine =
            if index == 0,
              do: state.workflows["default"].engine,
              else: elem(FlowEngine.start_link(), 1)

          definition = Map.get(data, "definition", %{})

          case FlowEngine.replace_definition(engine, definition, state.registry) do
            :ok when is_binary(id) ->
              workflow = %{
                id: id,
                name: Map.get(data, "name", id),
                enabled: Map.get(data, "enabled", true),
                engine: engine
              }

              put_in(acc.workflows[id], workflow)

            error ->
              warn_restore(error)
              if index != 0, do: GenServer.stop(engine)
              acc
          end
        end)

      if map_size(restored.workflows) == 0 do
        state
      else
        active_id =
          if Map.has_key?(restored.workflows, active),
            do: active,
            else: restored.workflows |> Map.keys() |> Enum.sort() |> hd()

        %{restored | active: active_id}
      end
    end
  end

  defp warn_restore(reason) do
    require Logger
    Logger.warning("无法恢复工作流：#{inspect(reason)}")
  end
end
