defmodule FlowEngine do
  @moduledoc "受监督的内存节点流运行时，支持有向环路。"

  use GenServer

  defstruct nodes: %{},
            edges: %{},
            status: :stopped,
            supervisor: nil,
            node_opts: [],
            max_hops: 1000,
            events: [],
            event_id: 0,
            subscribers: %{}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def add_node(server, id, module, config \\ %{}),
    do: GenServer.call(server, {:add_node, id, module, config})

  def add_node(server, id, module, config, metadata),
    do: GenServer.call(server, {:add_node, id, module, config, metadata})

  def remove_node(server, id), do: GenServer.call(server, {:remove_node, id})

  @doc "查询节点定义。"
  def get_node(server, id), do: GenServer.call(server, {:get_node, id})

  @doc "更新节点配置或节点元数据。配置变化会重新初始化节点进程。"
  def update_node(server, id, attrs), do: GenServer.call(server, {:update_node, id, attrs})

  @doc "只更新节点编辑器元数据，不重新初始化节点。"
  def update_node_metadata(server, id, metadata),
    do: GenServer.call(server, {:update_node_metadata, id, metadata})

  def connect(server, source, output_port, target, input_port),
    do: GenServer.call(server, {:connect, source, output_port, target, input_port})

  @doc "删除一条节点连接。"
  def disconnect(server, source, output_port, target, input_port),
    do: GenServer.call(server, {:disconnect, source, output_port, target, input_port})

  @doc "清空当前工作流中的节点和连接。"
  def reset(server), do: GenServer.call(server, :reset)

  @doc "用前端工作流定义替换当前工作流。"
  def replace_definition(server, workflow, resolver),
    do: replace_definition_sync(server, workflow, resolver)

  defp replace_definition_sync(server, workflow, resolver) do
    with :ok <- FlowEngine.WorkflowLoader.validate(workflow, resolver) do
      snapshot = checkpoint_snapshot(server)

      result =
        with :ok <- reset(server),
             :ok <- FlowEngine.WorkflowLoader.load(server, workflow, resolver),
             :ok <- restore_running_status(server, snapshot.status) do
          :ok
        end

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          case restore_checkpoint(server, snapshot) do
            :ok -> {:error, reason}
            {:error, restore_reason} -> {:error, {:rollback_failed, reason, restore_reason}}
          end
      end
    end
  end

  defp restore_running_status(server, :running), do: start_workflow(server)
  defp restore_running_status(_server, :stopped), do: :ok

  def start_workflow(server), do: GenServer.call(server, :start_workflow)
  def stop_workflow(server), do: GenServer.call(server, :stop_workflow)

  def send_message(server, id, input_port, message),
    do: GenServer.call(server, {:send_message, id, input_port, message})

  def status(server), do: GenServer.call(server, :status)
  def export_definition(server), do: GenServer.call(server, :export_definition)
  @doc "导出包含节点运行态的 checkpoint 快照。"
  def checkpoint_snapshot(server), do: GenServer.call(server, :checkpoint_snapshot)
  @doc "恢复 checkpoint 快照中的节点、连接和运行状态。"
  def restore_checkpoint(server, snapshot),
    do: GenServer.call(server, {:restore_checkpoint, snapshot})

  def events(server), do: GenServer.call(server, :events)

  @doc "订阅运行事件，并原子获取最近事件快照。"
  def subscribe(server, subscriber \\ self()),
    do: GenServer.call(server, {:subscribe, subscriber})

  @doc "取消运行事件订阅。"
  def unsubscribe(server, subscriber \\ self()),
    do: GenServer.call(server, {:unsubscribe, subscriber})

  @impl true
  def init(opts) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    {:ok,
     %__MODULE__{
       supervisor: supervisor,
       node_opts: opts,
       max_hops: Keyword.get(opts, :max_hops, 1000)
     }}
  end

  @impl true
  def handle_call({:add_node, id, module, config}, _from, state) do
    handle_call({:add_node, id, module, config, %{}}, self(), state)
  end

  def handle_call({:add_node, id, module, config, metadata}, _from, state) do
    with :ok <- ensure_new_id(state, id),
         :ok <- ensure_node_module(module),
         {:ok, pid} <- start_node(state, id, module, config) do
      node = %{pid: pid, module: module, config: config, metadata: metadata}
      {:reply, :ok, put_in(state.nodes[id], node)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_node, id}, _from, state) do
    case Map.pop(state.nodes, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {%{pid: pid}, nodes} ->
        _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
        {:reply, :ok, %{state | nodes: nodes, edges: remove_edges(state.edges, id)}}
    end
  end

  def handle_call({:get_node, id}, _from, state) do
    case Map.get(state.nodes, id) do
      nil -> {:reply, {:error, :not_found}, state}
      node -> {:reply, {:ok, node_definition(id, node)}, state}
    end
  end

  def handle_call({:update_node_metadata, id, metadata}, _from, state) do
    case Map.get(state.nodes, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      node ->
        updated_metadata = Map.merge(node.metadata, normalize_map(metadata))

        if state.status == :running do
          if node_enabled?(updated_metadata),
            do: FlowEngine.NodeServer.start_node(node.pid),
            else: FlowEngine.NodeServer.stop_node(node.pid)
        end

        next = put_in(state.nodes[id].metadata, updated_metadata)
        {:reply, {:ok, node_definition(id, next.nodes[id])}, next}
    end
  end

  def handle_call({:update_node, id, attrs}, _from, state) do
    case Map.get(state.nodes, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      node ->
        attrs = normalize_map(attrs)
        config = Map.get(attrs, :config, node.config)
        module = Map.get(attrs, :module, node.module)
        metadata = Map.merge(node.metadata, Map.get(attrs, :metadata, %{}))

        with :ok <- ensure_node_module(module),
             {:ok, pid} <- start_node(state, id, module, config) do
          _ = DynamicSupervisor.terminate_child(state.supervisor, node.pid)
          next_node = %{node | pid: pid, module: module, config: config, metadata: metadata}
          next = put_in(state.nodes[id], next_node)

          if state.status == :running and node_enabled?(metadata),
            do: FlowEngine.NodeServer.start_node(pid)

          {:reply, {:ok, node_definition(id, next_node)}, next}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:connect, source, output_port, target, input_port}, _from, state) do
    if Map.has_key?(state.nodes, source) and Map.has_key?(state.nodes, target) do
      key = {source, output_port}
      edge = {target, input_port}

      {:reply, :ok,
       %{state | edges: Map.update(state.edges, key, [edge], &Enum.uniq([edge | &1]))}}
    else
      {:reply, {:error, :node_not_found}, state}
    end
  end

  def handle_call({:disconnect, source, output_port, target, input_port}, _from, state) do
    key = {source, output_port}

    case Map.get(state.edges, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      targets ->
        next_targets = Enum.reject(targets, &(&1 == {target, input_port}))

        next_edges =
          if next_targets == [],
            do: Map.delete(state.edges, key),
            else: Map.put(state.edges, key, next_targets)

        if length(next_targets) == length(targets) do
          {:reply, {:error, :not_found}, state}
        else
          {:reply, :ok, %{state | edges: next_edges}}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    stop_all_nodes(state)
    {:reply, :ok, %{state | nodes: %{}, edges: %{}, status: :stopped}}
  end

  def handle_call(:start_workflow, _from, %{status: :running} = state), do: {:reply, :ok, state}

  def handle_call(:start_workflow, _from, state) do
    Enum.each(state.nodes, fn {_id, node} ->
      if node_enabled?(node.metadata), do: FlowEngine.NodeServer.start_node(node.pid)
    end)

    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:stop_workflow, _from, %{status: :stopped} = state), do: {:reply, :ok, state}

  def handle_call(:stop_workflow, _from, state) do
    Enum.each(state.nodes, fn {_id, %{pid: pid}} -> FlowEngine.NodeServer.stop_node(pid) end)
    {:reply, :ok, %{state | status: :stopped}}
  end

  def handle_call({:send_message, id, input_port, message}, _from, state) do
    case Map.get(state.nodes, id) do
      nil ->
        {:reply, {:error, :node_not_found}, state}

      %{pid: pid, metadata: metadata} ->
        if node_enabled?(metadata), do: send(pid, {:flow_message, input_port, message, 0})
        {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state) do
    nodes = Map.new(state.nodes, fn {id, node} -> {id, node_definition(id, node)} end)
    {:reply, %{status: state.status, nodes: nodes, edges: state.edges}, state}
  end

  def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    subscribers =
      if Map.has_key?(state.subscribers, subscriber) do
        state.subscribers
      else
        Map.put(state.subscribers, subscriber, Process.monitor(subscriber))
      end

    {:reply, Enum.reverse(state.events), %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    {reference, subscribers} = Map.pop(state.subscribers, subscriber)
    if reference, do: Process.demonitor(reference, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:export_definition, _from, state) do
    nodes =
      Enum.map(state.nodes, fn {id, node} ->
        metadata = Map.drop(node.metadata, [:id, :type, :config])

        metadata
        |> Map.put(:id, id)
        |> Map.put(:type, Map.get(node.metadata, :type, node.module))
        |> Map.put(:config, node.config)
        |> stringify_definition_keys()
      end)

    connections =
      Enum.flat_map(state.edges, fn {{source, source_output}, targets} ->
        Enum.map(targets, fn {target, target_input} ->
          %{
            "source" => source,
            "target" => target,
            "sourceOutput" => source_output,
            "targetInput" => target_input
          }
        end)
      end)

    {:reply, %{"nodes" => nodes, "connections" => connections}, state}
  end

  def handle_call(:checkpoint_snapshot, _from, state) do
    nodes =
      Map.new(state.nodes, fn {id, node} ->
        snapshot = FlowEngine.NodeServer.snapshot(node.pid)

        {id,
         %{
           module: node.module,
           config: node.config,
           metadata: node.metadata,
           node_state: snapshot.node_state,
           running: snapshot.running
         }}
      end)

    {:reply, %{version: 1, status: state.status, nodes: nodes, edges: state.edges}, state}
  end

  def handle_call({:restore_checkpoint, snapshot}, _from, state) when is_map(snapshot) do
    with {:ok, next} <- restore_snapshot(state, snapshot) do
      {:reply, :ok, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:restore_checkpoint, _snapshot}, _from, state),
    do: {:reply, {:error, :invalid_checkpoint}, state}

  @impl true
  def handle_info({:node_started, id, pid}, state) do
    case Map.get(state.nodes, id) do
      nil ->
        {:noreply, state}

      node ->
        if state.status == :running and node_enabled?(node.metadata),
          do: FlowEngine.NodeServer.start_node(pid)

        next = put_in(state.nodes[id], %{node | pid: pid})
        {:noreply, record_event(next, id, :started, %{})}
    end
  end

  def handle_info({:node_output, source, _output_port, _message, hops}, state)
      when hops >= state.max_hops do
    {:noreply, record_event(state, source, :dropped, %{reason: :max_hops})}
  end

  def handle_info({:node_output, source, output_port, message, hops}, state) do
    for {target, input_port} <- Map.get(state.edges, {source, output_port}, []) do
      case Map.get(state.nodes, target) do
        %{pid: pid, metadata: metadata} ->
          if node_enabled?(metadata), do: send(pid, {:flow_message, input_port, message, hops})

        _ ->
          :ok
      end
    end

    preview = inspect(message, limit: 12, printable_limit: 512)
    {:noreply, record_event(state, source, :output, %{port: output_port, preview: preview})}
  end

  def handle_info({:node_event, node, type, details}, state),
    do: {:noreply, record_event(state, node, type, details)}

  def handle_info({:DOWN, reference, :process, subscriber, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, subscriber) do
        ^reference -> Map.delete(state.subscribers, subscriber)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp start_node(state, id, module, config),
    do:
      DynamicSupervisor.start_child(
        state.supervisor,
        {FlowEngine.NodeServer, {id, module, config, self(), state.node_opts}}
      )

  defp ensure_new_id(state, id),
    do: if(Map.has_key?(state.nodes, id), do: {:error, :already_exists}, else: :ok)

  defp ensure_node_module(module),
    do:
      if(function_exported?(module, :init, 1) and function_exported?(module, :handle_message, 3),
        do: :ok,
        else: {:error, :invalid_node}
      )

  defp node_enabled?(metadata),
    do: Map.get(metadata, :enabled, Map.get(metadata, "enabled", true)) != false

  defp remove_edges(edges, id),
    do:
      Enum.reduce(edges, %{}, fn {{source, port}, targets}, acc ->
        if source == id,
          do: acc,
          else: Map.put(acc, {source, port}, Enum.reject(targets, &(elem(&1, 0) == id)))
      end)

  defp stringify_definition_keys(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.new()
  end

  defp node_definition(id, node) do
    metadata = Map.drop(node.metadata, [:id, :type, :config])

    metadata
    |> Map.put(:id, id)
    |> Map.put(:type, Map.get(node.metadata, :type, node.module))
    |> Map.put(:config, node.config)
    |> stringify_definition_keys()
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize_map(_), do: %{}

  defp stop_all_nodes(state) do
    Enum.each(state.nodes, fn {_id, %{pid: pid}} ->
      _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
    end)
  end

  defp restore_snapshot(state, snapshot) do
    nodes_data = Map.get(snapshot, :nodes, Map.get(snapshot, "nodes"))
    edges = Map.get(snapshot, :edges, Map.get(snapshot, "edges", %{}))
    status = Map.get(snapshot, :status, Map.get(snapshot, "status", :stopped))

    if not is_map(nodes_data) or not is_map(edges) or status not in [:running, :stopped] do
      {:error, :invalid_checkpoint}
    else
      stop_all_nodes(state)

      result =
        Enum.reduce_while(nodes_data, {:ok, %{}}, fn {id, data}, {:ok, acc} ->
          module = Map.get(data, :module, Map.get(data, "module"))
          config = Map.get(data, :config, Map.get(data, "config", %{}))
          metadata = Map.get(data, :metadata, Map.get(data, "metadata", %{}))

          with :ok <- ensure_node_module(module),
               {:ok, pid} <- start_node(state, id, module, config) do
            node_state = Map.get(data, :node_state, Map.get(data, "node_state"))
            FlowEngine.NodeServer.restore(pid, node_state)

            {:cont,
             {:ok,
              Map.put(acc, id, %{pid: pid, module: module, config: config, metadata: metadata})}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:error, reason} ->
          {:error, reason}

        {:ok, nodes} ->
          next = %{state | nodes: nodes, edges: normalize_edges(edges), status: :stopped}

          if status == :running,
            do: Enum.each(nodes, fn {_id, node} -> FlowEngine.NodeServer.start_node(node.pid) end)

          {:ok, %{next | status: status}}
      end
    end
  end

  defp normalize_edges(edges) do
    Map.new(edges, fn {key, targets} ->
      {normalize_edge_key(key), Enum.map(targets, &normalize_edge_target/1)}
    end)
  end

  defp normalize_edge_key({source, port}), do: {source, port}
  defp normalize_edge_key(key), do: key
  defp normalize_edge_target({target, port}), do: {target, port}
  defp normalize_edge_target(target), do: target

  defp record_event(state, node, type, details) do
    event = %{
      id: state.event_id + 1,
      node_id: node,
      type: type,
      details: details,
      timestamp: System.system_time(:millisecond)
    }

    Enum.each(state.subscribers, fn {subscriber, _reference} ->
      case Process.info(subscriber, :message_queue_len) do
        {:message_queue_len, length} when length < 1000 ->
          send(subscriber, {:flow_event, self(), event})

        _ ->
          :ok
      end
    end)

    %{state | event_id: event.id, events: Enum.take([event | state.events], 1000)}
  end
end
