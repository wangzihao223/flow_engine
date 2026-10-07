defmodule FlowEngine.Node do
  @moduledoc "串行工作流节点的行为约定。"

  @callback init(map()) :: {:ok, term()} | {:error, term()}
  @callback handle_message(non_neg_integer(), term(), term()) ::
              {:ok, term()}
              | {:emit, [{non_neg_integer(), term()}], term()}
              | {:error, term(), term()}
end
