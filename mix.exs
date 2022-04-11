defmodule Membrane.RTP.Plugin.MixProject do
  use Mix.Project

  @version "0.11.0"
  @github_url "https://github.com/membraneframework/membrane_rtp_plugin"

  def project do
    [
      app: :membrane_rtp_plugin,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # hex
      description: "Membrane Multimedia Framework plugin for RTP",
      package: package(),

      # docs
      name: "Membrane RTP plugin",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md", LICENSE: [title: License]],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        Membrane.RTP,
        Membrane.RTCP,
        Membrane.SRTP,
        Membrane.SRTCP
      ],
      groups_for_modules: [
        "RTP session": [~r/^Membrane\.RTP\.Session/],
        RTP: [~r/^Membrane\.RTP/],
        RTCP: [~r/^Membrane\.RTCP/],
        SRTP: [~r/^Membrane\.SRTP/]
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:membrane_telemetry_metrics,
       branch: "basic-functionality-implementation",
       github: "membraneframework/membrane_telemetry_metrics"},
      {:membrane_core, "~> 0.9.0"},
      {:membrane_rtp_format, "~> 0.3.1"},
      {:ex_libsrtp, "~> 0.3.0", optional: true},
      {:qex, "~> 0.5.1"},
      {:bunch, "~> 1.0"},
      {:heap, "~> 2.0.2"},
      {:bimap, "~> 1.1.0"},

      # Test
      {:membrane_rtp_h264_plugin, "~> 0.9", only: :test},
      {:membrane_rtp_mpegaudio_plugin, "~> 0.8", only: :test},
      {:membrane_h264_ffmpeg_plugin, "~> 0.18", only: :test},
      {:membrane_pcap_plugin,
       github: "membraneframework/membrane_pcap_plugin", tag: "v0.5.0", only: :test},
      {:membrane_hackney_plugin, "~> 0.7", only: :test},

      # Dev
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:credo, "~> 1.5", only: :dev, runtime: false}
    ]
  end
end
