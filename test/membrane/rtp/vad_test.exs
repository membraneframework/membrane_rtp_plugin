defmodule Membrane.RTP.VADTest do
  @moduledoc """
  Voice Activity Detection.

  The initial timestamp represents a random RTP timestamp. Since RTP timestamps for a
  session begin at a random unsigned 32-bit integer, the value of number is not important.
  """
  use ExUnit.Case

  alias Membrane.RTP.VAD
  alias Membrane.RTP.VadUtils.{AudioLevelQueue, VadParams}

  ExUnit.Case.register_attribute(__MODULE__, :buffer_interval)
  ExUnit.Case.register_attribute(__MODULE__, :vad_threshold)

  @default_vad_id 1
  @default_buffer_interval 20
  @max_levels_length VadParams.target_levels_length()

  defp calculate_buffer_time_delta(ctx) do
    buffer_interval = ctx.registered.buffer_interval || @default_buffer_interval
    [time_delta: 1 / buffer_interval]
  end

  defp generate_initial_timestamp(_ctx),
    do: [initial_timestamp: :rand.uniform(4_294_967_295)]

  defp get_vad_attribute_or_default(ctx, attribute) do
    Map.get(ctx.registered, attribute) ||
      VAD.options()
      |> Keyword.fetch!(attribute)
      |> Keyword.fetch!(:default)
  end

  defp setup_vad_options(ctx) do
    [
      vad_threshold: get_vad_attribute_or_default(ctx, :vad_threshold)
    ]
  end

  defp setup_initial_vad_state(ctx) do
    {[], state} =
      VAD.handle_init(nil, %{
        vad_id: @default_vad_id,
        vad_threshold: ctx.vad_threshold
      })

    [state: state]
  end

  defp rtp_buffer(volume, timestamp) when volume in -127..0 do
    level = -volume
    data = <<1::1, level::7>>

    rtp_metadata = %{
      csrcs: [],
      extensions: [
        %Membrane.RTP.Header.Extension{
          identifier: @default_vad_id,
          data: data
        }
      ],
      padding_size: 0,
      marker: false,
      payload_type: 111,
      sequence_number: 16_503,
      ssrc: 1_464_407_876,
      timestamp: timestamp,
      total_header_size: 20
    }

    %Membrane.Buffer{metadata: %{rtp: rtp_metadata}, payload: <<>>}
  end

  defp iterate_for(
         buffers: buffer_count,
         volume: volume,
         initial: state,
         time_delta: time_delta
       ) do
    iterate_for(
      volumes: List.duplicate(volume, buffer_count),
      initial: state,
      time_delta: time_delta
    )
  end

  defp iterate_for(volumes: volumes, initial: state, time_delta: time_delta) do
    original_timestamp = state.current_timestamp

    volumes
    |> Enum.with_index()
    |> Enum.reduce(state, fn {volume, index}, state ->
      new_timestamp = original_timestamp + time_delta * (index + 1)
      buffer = rtp_buffer(volume, new_timestamp)

      {_actions, new_state} = VAD.handle_process(:input, buffer, %{}, state)
      new_state
    end)
  end

  defp process_buffer(buffer, state) do
    {_actions, new_state} = VAD.handle_process(:input, buffer, %{}, state)
    new_state
  end

  defp levels_len(state), do: AudioLevelQueue.len(state.audio_levels)

  describe "handle_process" do
    setup [
      :setup_vad_options,
      :setup_initial_vad_state,
      :generate_initial_timestamp,
      :calculate_buffer_time_delta
    ]

    test "keeps audio levels length", ctx do
      %{
        state: state,
        time_delta: time_delta,
        initial_timestamp: initial_timestamp
      } = ctx

      assert levels_len(state) == 0

      state = process_buffer(rtp_buffer(-127, initial_timestamp), state)
      assert levels_len(state) == 1

      half_of_max_length = div(@max_levels_length, 2)

      state =
        iterate_for(
          buffers: half_of_max_length,
          volume: -50,
          initial: state,
          time_delta: time_delta
        )

      assert levels_len(state) == half_of_max_length + 1

      rest_levels_length = @max_levels_length - half_of_max_length - 1

      state =
        iterate_for(
          buffers: rest_levels_length,
          volume: -50,
          initial: state,
          time_delta: time_delta
        )

      assert levels_len(state) == @max_levels_length

      state = iterate_for(buffers: 100, volume: -100, initial: state, time_delta: time_delta)

      assert levels_len(state) == @max_levels_length
    end

    test "maps levels from -127 and 0 to 0 and 127", ctx do
      %{
        time_delta: time_delta,
        state: state,
        initial_timestamp: initial_timestamp
      } = ctx

      state = process_buffer(rtp_buffer(-127, initial_timestamp), state)
      assert AudioLevelQueue.to_list(state.audio_levels) == [0]

      rtp_volumes = -126..0
      state = iterate_for(volumes: rtp_volumes, initial: state, time_delta: time_delta)

      expected_audio_levels = 0..127 |> Enum.reverse() |> Enum.take(@max_levels_length)

      assert AudioLevelQueue.to_list(state.audio_levels) == expected_audio_levels
    end

    test "transitions between :speech and :silence", ctx do
      %{
        time_delta: time_delta,
        state: state,
        initial_timestamp: initial_timestamp
      } = ctx

      state = process_buffer(rtp_buffer(-127, initial_timestamp), state)
      assert state.vad == :silence

      state = iterate_for(buffers: 100, volume: 0, initial: state, time_delta: time_delta)
      assert state.vad == :speech

      state = iterate_for(buffers: 100, volume: -100, initial: state, time_delta: time_delta)

      assert state.vad == :silence
    end

    @buffer_interval 1000
    test "resets the state when RTP timestamps roll over", ctx do
      %{state: state} = ctx

      max_32bit_int = 4_294_967_295
      initial_timestamp = max_32bit_int - 5 - 2000

      state = process_buffer(rtp_buffer(-127, initial_timestamp), state)
      state = process_buffer(rtp_buffer(-127, initial_timestamp + 1000), state)
      state = process_buffer(rtp_buffer(-5, 995), state)
      state = process_buffer(rtp_buffer(-5, 1995), state)
      state = process_buffer(rtp_buffer(-5, 2995), state)

      assert levels_len(state) === 2
    end

    test "ignore RTP packets that arrive out of order", ctx do
      %{
        time_delta: time_delta,
        state: state,
        initial_timestamp: initial_timestamp
      } = ctx

      state = process_buffer(rtp_buffer(-127, initial_timestamp), state)
      state = process_buffer(rtp_buffer(-127, initial_timestamp - time_delta), state)
      state = process_buffer(rtp_buffer(-50, initial_timestamp + time_delta * 2), state)

      assert levels_len(state) === 2
    end

    @buffer_interval 1000
    test "ignore RTP packets that arrive out of order, from before a rollover", ctx do
      %{state: state} = ctx

      max_32bit_int = 4_294_967_295
      initial_timestamp = max_32bit_int - 5 - 1000

      state = process_buffer(rtp_buffer(-5, 995), state)
      state = process_buffer(rtp_buffer(-127, initial_timestamp + 1000), state)
      state = process_buffer(rtp_buffer(-5, 1995), state)

      assert levels_len(state) === 2
    end
  end
end
