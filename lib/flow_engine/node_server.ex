defmodule FlowEngine.NodeServer do
  @moduledoc "负责单个节点的消息串行处理，并限制队列长度。"

  use GenServer

  def start_link({id, module, config, engine, opts}),
    do: GenServer.start_link(__MODULE__, {id, module, config, engine, opts})

  def start_node(pid), do: send(pid, :start_node)
  def stop_node(pid), do: send(pid, :stop_node)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def restore(pid, node_state), do: GenServer.call(pid, {:restore, node_state})

  @impl true
  def init({id, module, config, engine, opts}) do
    case module.init(config) do
      {:ok, node_state} ->
        send(self(), :ready)

        {:ok,
         %{
           id: id,
           module: module,
           engine: engine,
           node_state: node_state,
           queue: :queue.new(),
           queue_length: 0,
           max_queue: Keyword.get(opts, :max_queue, 1000),
           running: false
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, %{node_state: state.node_state, running: state.running}, state}

  def handle_call({:restore, node_state}, _from, state),
    do: {:reply, :ok, %{state | node_state: node_state}}

  @impl true
  def handle_info(:ready, state) do
    send(state.engine, {:node_started, state.id, self()})
    {:noreply, state}
  end

  def handle_info(:start_node, state), do: {:noreply, drain(%{state | running: true})}
  def handle_info(:stop_node, state), do: {:noreply, %{state | running: false}}

  def handle_info({:flow_message, input_port, message, hops}, %{queue_length: length} = state) do
    if length >= state.max_queue do
      send(state.engine, {:node_event, state.id, :dropped, :queue_full})
      {:noreply, state}
    else
      queue = :queue.in({input_port, message, hops}, state.queue)
      {:noreply, drain(%{state | queue: queue, queue_length: length + 1})}
    end
  end

  def handle_info(:drain, state), do: {:noreply, drain(state)}

  defp drain(%{running: false} = state), do: state
  defp drain(%{queue_length: 0} = state), do: state

  defp drain(state) do
    {{:value, {input_port, message, hops}}, queue} = :queue.out(state.queue)
    next = %{state | queue: queue, queue_length: state.queue_length - 1}
    result = state.module.handle_message(input_port, message, state.node_state)
    next = apply_result(result, next, hops + 1)
    if next.queue_length > 0, do: send(self(), :drain)
    next
  end

  defp apply_result({:ok, node_state}, state, _hops), do: %{state | node_state: node_state}

  defp apply_result({:emit, outputs, node_state}, state, hops) do
    Enum.each(outputs, fn {port, message} ->
      send(state.engine, {:node_output, state.id, port, message, hops})
    end)

    %{state | node_state: node_state}
  end

  defp apply_result({:error, reason, node_state}, state, _hops) do
    send(state.engine, {:node_event, state.id, :error, reason})
    %{state | node_state: node_state}
  end

  defp apply_result(other, state, _hops) do
    send(state.engine, {:node_event, state.id, :error, {:invalid_result, other}})
    state
  end
end
