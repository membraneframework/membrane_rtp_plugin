defmodule Membrane.RTP.Plugin.MixProject do
  use Mix.Project

  @version "0.31.2"
  @github_url "https://github.com/membraneframework/membrane_rtp_plugin"

  def project do
    [
      app: :membrane_rtp_plugin,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "Core plugin for sending/receiving RTP/RTCP packets (powers WebRTC/RTSP).",
      package: package(),

      # docs
      name: "Membrane RTP plugin",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs(),
      aliases: [docs: ["docs", &prepend_llms_links/1]]
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.0"},
      {:membrane_rtp_format, "~> 0.11.0"},
      {:membrane_funnel_plugin, "~> 0.9.0"},
      {:membrane_telemetry_metrics, "~> 0.1.0"},
      {:ex_libsrtp, "~> 0.6.0 or ~> 0.7.0", optional: true},
      {:ex_rtp, "~> 0.4.0"},
      {:ex_rtcp, "~> 0.4.0"},
      {:qex, "~> 0.5.1"},
      {:bunch, "~> 1.5"},
      {:heap, "~> 2.0.2"},
      {:bimap, "~> 1.2"},

      # Test
      {:membrane_rtp_h264_plugin, "~> 0.20.1", only: :test},
      {:membrane_rtp_aac_plugin, "~> 0.9.3", only: :test},
      {:membrane_rtp_mpegaudio_plugin, "~> 0.14.1", only: :test},
      {:membrane_h264_ffmpeg_plugin, "~> 0.31.0", only: :test},
      {:membrane_h26x_plugin, "~> 0.10.2", only: :test},
      {:membrane_aac_plugin, "~> 0.19.0", only: :test},
      {:membrane_mp4_plugin, "~> 0.35.0", only: :test},
      {:membrane_pcap_plugin,
       github: "membraneframework/membrane_pcap_plugin", tag: "v0.9.0", only: :test},
      {:membrane_hackney_plugin, "~> 0.11.0", only: :test},
      {:membrane_realtimer_plugin, "~> 0.10.1", only: :test},

      # Dev
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.5", only: :dev, runtime: false}
    ]
  end

  defp dialyzer() do
    opts = [
      plt_add_apps: [:ex_libsrtp],
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
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

  defp docs do
    [
      main: "readme",
      extras: ["README.md", LICENSE: [title: License]],
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

  defp prepend_llms_links(_) do
    output_dir = docs()[:output] || "doc"
    path = Path.join(output_dir, "llms.txt")

    if File.exists?(path) do
      existing = File.read!(path)

      footer = """


      ## See Also

      - [Membrane Framework AI Skill](https://hexdocs.pm/membrane_core/skill.md)
      - [Membrane Core](https://hexdocs.pm/membrane_core/llms.txt)
      """

      File.write!(path, String.trim_trailing(existing) <> footer)
    else
      IO.warn("#{path} not found — llms.txt was not generated, check your ex_doc configuration")
    end
  end
end
