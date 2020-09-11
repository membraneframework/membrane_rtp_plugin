defmodule Membrane.RTP.SerializerTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.Testing

  defmodule Pipeline do
    use Membrane.Pipeline

    defmodule Realtimer do
      use Membrane.Filter

      def_input_pad :input, caps: :any, demand_unit: :buffers
      def_output_pad :output, caps: :any, mode: :push

      @impl true
      def handle_init(_opts) do
        {:ok, %{timestamp: 0}}
      end

      @impl true
      def handle_prepared_to_playing(_ctx, state) do
        {{:ok, start_timer: {:timer, :no_interval}, demand: {:input, 1}}, state}
      end

      @impl true
      def handle_process(:input, buffer, _ctx, state) do
        use Ratio
        interval = buffer.metadata.timestamp - state.timestamp
        state = %{state | timestamp: buffer.metadata.timestamp}
        {{:ok, buffer: {:output, buffer}, timer_interval: {:timer, interval}}, state}
      end

      @impl true
      def handle_tick(:timer, _ctx, state) do
        {{:ok, demand: {:input, 1}, timer_interval: {:timer, :no_interval}}, state}
      end

      @impl true
      def handle_playing_to_prepared(_ctx, state) do
        {{:ok, stop_timer: :timer}, state}
      end
    end

    @impl true
    def handle_init(_options) do
      children = [
        hackney: %Membrane.Element.Hackney.Source{
          location: "https://membraneframework.github.io/static/video-samples/test-video.h264"
        },
        realtimer: Realtimer,
        parser: %Membrane.Element.FFmpeg.H264.Parser{framerate: {30, 1}},
        payloader: Membrane.RTP.H264.Payloader,
        serializer: %Membrane.RTP.Serializer{ssrc: 1234},
        udp_sink: %Membrane.Element.UDP.Sink{
          destination_address: {127, 0, 0, 1},
          destination_port_no: 1234
        }
      ]

      links = [
        link(:hackney)
        |> to(:parser)
        |> to(:realtimer)
        |> to(:payloader)
        |> to(:serializer)
        |> to(:udp_sink)
      ]

      {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
    end
  end

  test "flow" do
    {:ok, pipeline} = Testing.Pipeline.start_link(%Testing.Pipeline.Options{module: Pipeline})
    Pipeline.play(pipeline)
    assert_end_of_stream(pipeline, :udp_sink, :input, 100_000)
  end
end
