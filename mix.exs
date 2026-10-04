defmodule Modbus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tallakt/yamodbus"

  def project do
    [
      app: :yamodbus,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      description:
        "Modbus in pure Elixir: TCP, TLS (Modbus/TCP Security), RTU and ASCII " <>
          "clients and servers, with many requests at once on one TCP connection, " <>
          "for talking to PLCs, drives and meters.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      # With socat installed for the serial line tests, as in CI.
      test_coverage: [summary: [threshold: 82], ignore_modules: [Modbus.Test.Pty]],
      dialyzer: [
        # Kept between runs, and between CI jobs by its cache.
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        plt_add_apps: [:circuits_uart],
        # Not :missing_return: the client's helpers promise less than request/4 can give back,
        # which is what they can.
        flags: [:error_handling, :extra_return, :unmatched_returns]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "NOTICE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Clients and servers": [Modbus, Modbus.Client, Modbus.Server, Modbus.Memory],
        Encoding: [Modbus.PDU, Modbus.TCP, Modbus.RTU, Modbus.ASCII]
      ]
    ]
  end

  def application do
    [
      # OTP's own TLS, for Modbus/TCP Security
      extra_applications: [:crypto, :public_key, :ssl]
    ]
  end

  defp deps do
    [
      # Only for serial lines, RTU and ASCII: an application that uses them adds it too.
      {:circuits_uart, "~> 1.5", optional: true},
      # Only for the fuzz and property tests.
      {:stream_data, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
