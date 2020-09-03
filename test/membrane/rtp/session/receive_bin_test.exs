defmodule Membrane.RTP.Session.ReceiveBinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP
  alias Membrane.Testing

  @rtp_stream %{
    pcap: "test/fixtures/rtp/session/demo_rtp.pcap",
    audio: %{ssrc: 439_017_412, frames_n: 20},
    video: %{ssrc: 670_572_639, frames_n: 287}
  }
  @srtp_stream %{
    pcap: "test/fixtures/rtp/session/srtp.pcap",
    audio: %{ssrc: 1_445_851_800, frames_n: 160},
    video: %{ssrc: 3_546_707_599, frames_n: 798},
    srtp_policies: [
      %SRTP.Policy{
        ssrc: :any_inbound,
        key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
    ]
  }

  @fmt_mapping %{96 => {:H264, 90_000}, 127 => {:MPA, 90_000}}

  defmodule Pauser do
    # move to Core.Testing?
    @moduledoc """
    Forwards buffers until reaching a pause point, i.e. after receiving a configured number of them.
    Continues forwarding upon receiving `:continue` message.
    """
    use Membrane.Filter
    def_input_pad :input, demand_unit: :buffers, caps: :any
    def_output_pad :output, caps: :any

    def_options pause_after: [
                  spec: [integer],
                  default: [],
                  description: "List of pause points."
                ]

    @impl true
    def handle_init(opts) do
      {:ok, Map.from_struct(opts) |> Map.merge(%{cnt: 0})}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, %{pause_after: [pause | _]} = state) do
      {{:ok, demand: {:input, min(size, pause - state.cnt)}}, state}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      {{:ok, demand: {:input, size}}, state}
    end

    @impl true
    def handle_process(:input, buffer, _ctx, state) do
      {{:ok, buffer: {:output, buffer}}, Map.update!(state, :cnt, &(&1 + 1))}
    end

    @impl true
    def handle_other(:continue, _ctx, state) do
      {{:ok, redemand: :output}, Map.update!(state, :pause_after, &tl/1)}
    end
  end

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(options) do
      spec = %ParentSpec{
        children: [
          pcap: %Membrane.Element.Pcap.Source{path: options.pcap_file},
          pauser: %Pauser{pause_after: [15]},
          rtp: %RTP.Session.ReceiveBin{
            fmt_mapping: options.fmt_mapping,
            rtcp_interval: options.rtcp_interval,
            secure?: options.srtp_policies != [],
            srtp_policies: options.srtp_policies
          },
          rtcp_source: %Testing.Source{output: options.rtcp_input},
          rtcp_sink: Testing.Sink
        ],
        links: [
          link(:pcap) |> to(:pauser) |> to(:rtp) |> via_out(:rtcp_output) |> to(:rtcp_sink),
          link(:rtcp_source) |> via_in(:rtcp_input) |> to(:rtp)
        ]
      }

      {{:ok, spec: spec}, %{}}
    end

    @impl true
    def handle_notification({:new_rtp_stream, ssrc, _pt}, :rtp, _ctx, state) do
      spec = %ParentSpec{
        children: [
          {{:sink, ssrc}, Testing.Sink}
        ],
        links: [
          link(:rtp) |> via_out(Pad.ref(:output, ssrc)) |> to({:sink, ssrc})
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification(_notification, _child, _ctx, state) do
      {:ok, state}
    end
  end

  test "RTP streams passes through RTP bin properly" do
    sender_report =
      %Membrane.RTCP.SenderReportPacket{
        reports: [],
        sender_info: %{
          rtp_timestamp: 555_689_664,
          sender_octet_count: 27843,
          sender_packet_count: 158,
          wallclock_timestamp: 1_582_306_181_225_999_999
        },
        ssrc: @rtp_stream.video.ssrc
      }
      |> Membrane.RTCP.Packet.to_binary()

    test_stream(@rtp_stream, sender_report)
  end

  test "SRTP streams passes through RTP bin properly" do
    encrypted_sender_report =
      <<128, 200, 0, 6, 222, 173, 190, 239, 42, 166, 210, 47, 206, 167, 216, 36, 40, 33, 84, 200,
        33, 116, 108, 233, 19, 36, 26, 247, 128, 0, 0, 1, 255, 96, 51, 225, 176, 61, 171, 239, 14,
        63>>

    test_stream(@srtp_stream, encrypted_sender_report)
  end

  defp test_stream(stream, sender_report) do
    {:ok, pipeline} =
      %Testing.Pipeline.Options{
        module: DynamicPipeline,
        custom_args: %{
          pcap_file: stream.pcap,
          fmt_mapping: @fmt_mapping,
          rtcp_input: [sender_report],
          rtcp_interval: Membrane.Time.second(),
          srtp_policies: Map.get(stream, :srtp_policies, [])
        }
      }
      |> Testing.Pipeline.start_link()

    Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    %{audio: %{ssrc: audio_ssrc}, video: %{ssrc: video_ssrc}} = stream
    assert_start_of_stream(pipeline, {:sink, ^video_ssrc})
    assert_start_of_stream(pipeline, {:sink, ^audio_ssrc})

    assert_sink_buffer(pipeline, :rtcp_sink, %Membrane.Buffer{})
    assert_sink_buffer(pipeline, :rtcp_sink, %Membrane.Buffer{})
    Testing.Pipeline.message_child(pipeline, :pauser, :continue)

    1..stream.video.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, {:sink, video_ssrc}, %Membrane.Buffer{})
    end)

    1..stream.audio.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, {:sink, audio_ssrc}, %Membrane.Buffer{})
    end)

    assert_end_of_stream(pipeline, {:sink, ^audio_ssrc})
    assert_end_of_stream(pipeline, {:sink, ^video_ssrc})
    Testing.Pipeline.stop(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :stopped)
  end
end
