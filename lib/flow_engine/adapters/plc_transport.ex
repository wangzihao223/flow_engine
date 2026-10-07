defmodule FlowEngine.Adapters.PLCTransport do
  @moduledoc "PLC 服务需要实现的传输接口。具体 PLC 协议由设备服务提供。"

  @callback read(map(), String.t(), pos_integer()) :: {:ok, term()} | {:error, term()}
  @callback write(map(), String.t(), term(), String.t(), pos_integer()) ::
              {:ok, term()} | {:error, term()}
end
