defmodule GenServerless.MixProject do
  use Mix.Project

  def project do
    [
      app: :gen_serverless,
      version: "0.0.1",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.8"},
      {:jason, "~> 1.0"},
      {:google_api_pub_sub, "~> 0.12"},
      {:google_api_datastore, "~> 0.9"},
      {:goth, "~> 1.1"}
    ]
  end
end
