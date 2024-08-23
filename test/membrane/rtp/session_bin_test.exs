defmodule Membrane.RTP.Session.BinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  require Membrane.Logger
  alias Membrane.RTP.PayloadFormat
  alias Membrane.Testing
  alias Membrane.{RemoteStream, RTCP, RTP}

  @rtp_input %{
    pcap: "test/fixtures/rtp/session/demo_rtp.pcap",
    audio: %{ssrc: 439_017_412, frames_n: 20},
    video: %{ssrc: 670_572_639, frames_n: 287}
  }
  @srtp_input %{
    pcap: "test/fixtures/rtp/session/srtp.pcap",
    audio: %{ssrc: 1_445_851_800, frames_n: 160},
    video: %{ssrc: 3_546_707_599, frames_n: 798},
    srtp_policies: [
      %ExLibSRTP.Policy{
        ssrc: :any_inbound,
        key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
    ]
  }
  @rtp_output %{
    video: %{ssrc: 1234, packets_n: 300}
  }

  @fmt_mapping %{96 => {:H264, 90_000}, 127 => {:MPA, 90_000}}

  # asserts all specified buffers were received by a sink in any order
  defp assert_specified_buffers(_pipeline, _sink, []), do: :ok

  defp assert_specified_buffers(pipeline, sink, match_funs) do
    assert_sink_buffer(pipeline, sink, buffer)

    case Enum.split_with(match_funs, & &1.(buffer)) do
      {[_matching_funs], match_funs} ->
        assert_specified_buffers(pipeline, sink, match_funs)

      {matching_funs, match_funs} ->
        raise "Expected the buffer #{inspect(buffer)} to match exactly one match function, while it matched #{inspect(matching_funs)}. Remaining funs: #{inspect(match_funs)}."
    end
  end

  defmodule Pauser do
    # move to Core.Testing?
    @moduledoc """
    Forwards buffers until reaching a pause point, i.e. after receiving a configured number of them.
    Continues forwarding upon receiving `:continue` message.
    """
    use Membrane.Filter
    def_input_pad :input, flow_control: :manual, demand_unit: :buffers, accepted_format: _any
    def_output_pad :output, accepted_format: _any, flow_control: :manual

    def_options pause_after: [
                  spec: [integer],
                  default: [],
                  description: "List of pause points."
                ]

    @impl true
    def handle_init(_ctx, opts) do
      {[], Map.from_struct(opts) |> Map.merge(%{cnt: 0})}
    end

    @impl true
    def handle_playing(_ctx, state) do
      {[stream_format: {:output, %Membrane.RemoteStream{type: :packetized}}], state}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, %{pause_after: [pause | _]} = state) do
      {[demand: {:input, min(size, pause - state.cnt)}], state}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      {[demand: {:input, size}], state}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[buffer: {:output, buffer}], Map.update!(state, :cnt, &(&1 + 1))}
    end

    @impl true
    def handle_parent_notification(:continue, _ctx, state) do
      {[redemand: :output], Map.update!(state, :pause_after, &tl/1)}
    end
  end

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, options) do
      rtp_input_ref = make_ref()

      {:ok, h264_payloader} = Membrane.RTP.PayloadFormatResolver.payloader(:H264)

      structure = [
        child(:pcap, %Membrane.Pcap.Source{path: options.input.pcap}),
        child(:pauser, %Pauser{pause_after: [15]}),
        child(:rtp, %RTP.SessionBin{
          fmt_mapping: options.fmt_mapping,
          rtcp_receiver_report_interval: options.rtcp_receiver_report_interval,
          secure?: Map.has_key?(options.input, :srtp_policies),
          srtp_policies: Map.get(options.input, :srtp_policies, []),
          receiver_ssrc_generator: fn [sender_ssrc | _local_ssrcs], _remote_ssrcs ->
            sender_ssrc
          end
        }),
        child(:hackney, %Membrane.Hackney.Source{
          location:
            "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/ffmpeg-testsrc.h264"
        }),
        child(:parser, %Membrane.H264.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_alignment: :nalu
        }),
        child(:rtp_sink, Testing.Sink),
        child(:rtcp_source, %Testing.Source{
          output: options.rtcp_input,
          stream_format: %RemoteStream{type: :packetized, content_format: RTCP}
        }),
        child(:rtcp_sink, Testing.Sink),
        get_child(:rtcp_source)
        |> via_in(:rtp_input)
        |> get_child(:rtp)
        |> via_out(Pad.ref(:rtcp_receiver_output, rtp_input_ref))
        |> get_child(:rtcp_sink),
        get_child(:pcap)
        |> get_child(:pauser)
        |> via_in(Pad.ref(:rtp_input, rtp_input_ref))
        |> get_child(:rtp),
        # in case of payload_and_depayload option being true,
        # session bin is responsible for payloading the stream
        #
        # to test the case where stream is already payloaded (payload_and_depayload being false)
        # we need to manually add payloader bin and then link it with the session bin
        if options.payload_and_depayload do
          get_child(:hackney)
          |> get_child(:parser)
          |> via_in(Pad.ref(:input, options.output.video.ssrc),
            options: [payloader: h264_payloader]
          )
          |> get_child(:rtp)
          |> via_out(Pad.ref(:rtp_output, options.output.video.ssrc),
            options: [encoding: :H264]
          )
          |> get_child(:rtp_sink)
        else
          # assume that incoming stream is already payloaded when entering session bin
          get_child(:hackney)
          |> get_child(:parser)
          |> child(:payloader, %RTP.PayloaderBin{
            payloader: h264_payloader,
            payload_type: PayloadFormat.get(:H264).payload_type,
            ssrc: options.output.video.ssrc,
            clock_rate: 90_000
          })
          |> via_in(Pad.ref(:input, options.output.video.ssrc))
          |> get_child(:rtp)
          |> via_out(Pad.ref(:rtp_output, options.output.video.ssrc),
            options: [encoding: :H264]
          )
          |> get_child(:rtp_sink)
        end
      ]

      {[spec: structure],
       %{fmt_mapping: options.fmt_mapping, payload_and_depayload: options.payload_and_depayload}}
    end

    @impl true
    def handle_child_notification({:new_rtp_stream, ssrc, pt, _extensions}, :rtp, _ctx, state) do
      {encoding, _clock_rate} = Map.fetch!(state.fmt_mapping, pt)

      depayloader =
        if state.payload_and_depayload do
          {:ok, depayloader} = RTP.PayloadFormatResolver.depayloader(encoding)

          depayloader
        else
          nil
        end

      structure =
        get_child(:rtp)
        |> via_out(Pad.ref(:output, ssrc),
          options: [depayloader: depayloader]
        )
        |> child({:sink, ssrc}, Testing.Sink)

      {[spec: structure], state}
    end

    @impl true
    def handle_child_notification(_notification, _child, _ctx, state) do
      {[], state}
    end
  end

  test "RTP streams passes through RTP bin properly" do
    sender_report =
      %Membrane.RTCP.SenderReportPacket{
        reports: [],
        sender_info: %{
          rtp_timestamp: 555_689_664,
          sender_octet_count: 27_843,
          sender_packet_count: 158,
          wallclock_timestamp: 1_582_306_181_225_999_999
        },
        ssrc: @rtp_input.video.ssrc
      }
      |> Membrane.RTCP.Packet.serialize()

    test_stream(
      @rtp_input,
      @rtp_output,
      sender_report,
      [@rtp_input.video.ssrc, @rtp_input.audio.ssrc],
      [@rtp_output.video.ssrc],
      true
    )

    test_stream(
      @rtp_input,
      @rtp_output,
      sender_report,
      [@rtp_input.video.ssrc, @rtp_input.audio.ssrc],
      [@rtp_output.video.ssrc],
      false
    )
  end

  test "SRTP streams passes through RTP bin properly" do
    encrypted_sender_report =
      <<128, 200, 0, 6, 222, 173, 190, 239, 42, 166, 210, 47, 206, 167, 216, 36, 40, 33, 84, 200,
        33, 116, 108, 233, 19, 36, 26, 247, 128, 0, 0, 1, 255, 96, 51, 225, 176, 61, 171, 239, 14,
        63>>

    test_stream(@srtp_input, @rtp_output, encrypted_sender_report, [], [], true)
    # test_stream(@srtp_input, @rtp_output, encrypted_sender_report, [], [], false)
  end

  defp test_stream(
         input,
         output,
         sender_report,
         rr_senders_ssrcs,
         _sr_senders_ssrcs,
         payload_and_depayload
       ) do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: DynamicPipeline,
        custom_args: %{
          input: input,
          output: output,
          fmt_mapping: @fmt_mapping,
          rtcp_input: [sender_report],
          rtcp_receiver_report_interval: Membrane.Time.second(),
          payload_and_depayload: payload_and_depayload
        }
      )

    %{audio: %{ssrc: audio_ssrc}, video: %{ssrc: video_ssrc}} = input

    assert_start_of_stream(pipeline, {:sink, ^video_ssrc})
    assert_start_of_stream(pipeline, {:sink, ^audio_ssrc})
    assert_start_of_stream(pipeline, :rtp_sink)
    assert_start_of_stream(pipeline, :rtcp_sink)

    rr_match_funs =
      Enum.map(
        rr_senders_ssrcs,
        &fn buffer ->
          case RTCP.Packet.parse(buffer.payload) do
            {:ok, [%RTCP.ReceiverReportPacket{reports: [%RTCP.ReportPacketBlock{ssrc: ^&1}]}]} ->
              true

            _result ->
              false
          end
        end
      )

    assert_specified_buffers(pipeline, :rtcp_sink, rr_match_funs)

    Testing.Pipeline.notify_child(pipeline, :pauser, :continue)

    1..input.video.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, {:sink, video_ssrc}, %Membrane.Buffer{})
    end)

    1..input.audio.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, {:sink, audio_ssrc}, %Membrane.Buffer{})
    end)

    1..output.video.packets_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, :rtp_sink, %Membrane.Buffer{})
    end)

    assert_end_of_stream(pipeline, {:sink, ^video_ssrc})
    Testing.Pipeline.terminate(pipeline)
  end
end
