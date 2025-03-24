defmodule Membrane.RTP.MuxerDemuxerTest do
  @moduledoc false
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Testing

  @input_path "test/fixtures/rtp/h264/bun.h264"

  defmodule MuxerDemuxerPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:source, %Membrane.File.Source{location: opts.input_path})
        |> child(:h264_parser, %Membrane.H264.Parser{
          output_alignment: :nalu,
          generate_best_effort_timestamps: %{framerate: {120, 1}}
        })
        |> child(:realtimer, Membrane.Realtimer)
        |> child(:rtp_h264_payloader, Membrane.RTP.H264.Payloader)
        |> child(:rtp_muxer, %Membrane.RTP.Muxer{use_srtp: opts.use_srtp})
        |> child(:rtp_demuxer, %Membrane.RTP.Demuxer{use_srtp: opts.use_srtp})
        |> via_out(:output,
          options: [stream_id: {:encoding_name, :H264}]
        )
        |> child(:rtp_h264_depayloader, Membrane.RTP.H264.Depayloader)
        |> child(:sink, %Membrane.File.Sink{location: opts.output_path})
      ]

      {[spec: spec], %{}}
    end
  end

  describe "Muxed and demuxed stream is the same as unchanged one" do
    @tag :tmp_dir
    test "when not using SRTP encryption", %{tmp_dir: tmp_dir} do
      perform_test(false, tmp_dir)
    end

    @tag :tmp_dir
    test "when using SRTP encryption", %{tmp_dir: tmp_dir} do
      policy = %ExLibSRTP.Policy{ssrc: :any_inbound, key: String.duplicate("a", 30)}
      perform_test([policy], tmp_dir)
    end
  end

  defp perform_test(use_srtp, tmp_dir) do
    output_path = Path.join(tmp_dir, "output.h264")

    pipeline =
      Testing.Pipeline.start_supervised!(
        module: MuxerDemuxerPipeline,
        custom_args: %{input_path: @input_path, output_path: output_path, use_srtp: use_srtp}
      )

    assert_start_of_stream(pipeline, :sink)
    assert_end_of_stream(pipeline, :sink, :input, 10_000)

    assert File.read!(@input_path) == File.read!(output_path)

    Testing.Pipeline.terminate(pipeline)
  end
end
