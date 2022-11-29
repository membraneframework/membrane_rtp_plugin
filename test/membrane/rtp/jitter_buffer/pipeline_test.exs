defmodule Membrane.RTP.JitterBuffer.PipelineTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP.BufferFactory
  alias Membrane.RTP.JitterBuffer, as: RTPJitterBuffer
  alias Membrane.Testing

  @seq_number_limit 65_536

  defmodule PushTestingSrc do
    use Membrane.Source
    alias Membrane.RTP.BufferFactory

    @seq_number_limit 65_536

    def_output_pad :output, accepted_format: _any, mode: :push

    def_options buffer_num: [spec: non_neg_integer()],
                buffer_delay_ms: [spec: non_neg_integer()],
                max_latency: [spec: non_neg_integer()]

    @impl true
    def handle_playing(
          _ctx,
          %{
            buffer_delay_ms: delay_ms,
            buffer_num: buffer_num,
            max_latency: max_latency
          } = state
        ) do
      now = System.monotonic_time(:millisecond)

      1..buffer_num
      |> Enum.each(fn n ->
        time =
          cond do
            # Delay less than max latency
            rem(n, 15) == 0 -> n * delay_ms + div(max_latency, 2)
            # Delay more than max latency
            rem(n, 19) == 0 -> n * delay_ms + max_latency * 2
            true -> n * delay_ms
          end

        if rem(n, 50) < 30 or rem(n, 50) > 32 do
          seq_number = rem(n, @seq_number_limit)
          Process.send_after(self(), {:push_buffer, seq_number}, now + time, abs: true)
        end
      end)

      {[stream_format: {:output, %Membrane.RTP{}}], state}
    end

    @impl true
    def handle_info({:push_buffer, n}, _ctx, state) do
      actions = [action_from_number(n)]
      {actions, state}
    end

    defp action_from_number(element),
      do: {:buffer, {:output, BufferFactory.sample_buffer(element)}}
  end

  test "Jitter Buffer works in a Pipeline with small latency" do
    test_pipeline(300, 10, 200 |> Membrane.Time.milliseconds())
  end

  test "Jitter Buffer works in a Pipeline with large latency" do
    test_pipeline(100, 30, 1000 |> Membrane.Time.milliseconds())
  end

  @tag :long_running
  @tag timeout: 70_000 * 10 + 10_000
  test "Jitter Buffer works in a long-running Pipeline with small latency" do
    test_pipeline(70_000, 10, 100 |> Membrane.Time.milliseconds())
  end

  defp test_pipeline(buffers, buffer_delay_ms, latency) do
    import Membrane.ChildrenSpec

    latency_ms = latency |> Membrane.Time.round_to_milliseconds()

    structure = [
      child(:source, %PushTestingSrc{
        buffer_num: buffers,
        buffer_delay_ms: buffer_delay_ms,
        max_latency: latency_ms
      })
      |> via_in(:input, target_queue_size: 50)
      |> child(:buffer, %RTPJitterBuffer{latency: latency, clock_rate: 8000})
      |> child(:sink, Testing.Sink)
    ]

    {:ok, _supervisor, pipeline} = Testing.Pipeline.start_link_supervised(structure: structure)

    assert_pipeline_setup(pipeline)
    assert_pipeline_play(pipeline)

    timeout = latency_ms + buffer_delay_ms + 200
    assert_start_of_stream(pipeline, :buffer, :input, 5000)
    assert_start_of_stream(pipeline, :sink, :input, timeout)

    Enum.each(1..buffers, fn n ->
      cond do
        rem(n, 50) >= 30 and rem(n, 50) <= 32 ->
          assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{}, timeout)

        rem(n, 19) == 0 and rem(n, 15) != 0 ->
          assert_sink_event(pipeline, :sink, %Membrane.Event.Discontinuity{}, timeout)

        true ->
          seq_num = rem(n, @seq_number_limit)

          assert_sink_buffer(
            pipeline,
            :sink,
            %Membrane.Buffer{
              metadata: %{rtp: %{sequence_number: ^seq_num}},
              payload: _
            },
            timeout
          )
      end
    end)

    Membrane.Pipeline.terminate(pipeline, blocking?: true)
  end
end
