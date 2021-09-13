defmodule EZTracer.MixProject do
  use Mix.Project

  def project do
    [
      app: :eztracer,
      version: "0.1.0",
      elixir: "~> 1.4",
      escript: escript()
    ]
  end

  defp escript do
    [main_module: EZTracer]
  end
end
