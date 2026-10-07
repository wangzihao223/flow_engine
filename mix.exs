defmodule FlowEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :flow_engine,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]

  defp deps do
    [{:bandit, "~> 1.6"}, {:plug, "~> 1.16"}, {:jason, "~> 1.4"}]
  end
end
