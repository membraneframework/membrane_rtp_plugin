defmodule Membrane.RTP.VADTest do
  @moduledoc """
  Voice Activity Detection.

  Notes for understanding these tests:
  * The initial timestamp represents a random RTP timestamp. Since RTP timestamps for a
    session begin at a random unsigned 32-bit integer, the value of number is not important.
  * Buffer intervals are tightly coupled to time deltas. For OPUS, the clock rate is `48000`
    and the interval between buffers is `20`, so the delta between RTP timestamps will be
    `960`. Tests that use different clock rates should set an appropriate buffer interval.
  """
  use ExUnit.Case

  alias Membrane.RTP.VAD

  ExUnit.Case.register_attribute(__MODULE__, :buffer_interval)
  ExUnit.Case.register_attribute(__MODULE__, :vad_threshold)

  @default_vad_id 1
  @default_buffer_interval 20

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
    original_timestamp = state.current_timestamp

    Enum.reduce(1..buffer_count, state, fn index, state ->
      new_timestamp = original_timestamp + time_delta * index
      buffer = rtp_buffer(volume, new_timestamp)

      {_actions, new_state} = VAD.handle_process(:input, buffer, %{}, state)
      new_state
    end)
  end

  defp process_buffer(buffer, state) do
    {_actions, new_state} = VAD.handle_process(:input, buffer, %{}, state)
    new_state
  end

  describe "handle_process" do
    setup [
      :setup_vad_options,
      :setup_initial_vad_state,
      :generate_initial_timestamp,
      :calculate_buffer_time_delta
    ]

    # TODO modify those tests and move to IsSpeakingEstimator
    # test "keeps running totals for buffers within a specific time window", ctx do
    #   %{
    #     time_delta: time_delta,
    #     state: state,
    #     initial_timestamp: initial_timestamp
    #   } = ctx

    #   buffer = rtp_buffer(-127, initial_timestamp)

    #   new_state = process_buffer(buffer, state)

    #   assert %{
    #            audio_levels_count: 1,
    #            audio_levels_sum: -127,
    #            vad: :silence
    #          } = new_state

    #   buffer = rtp_buffer(-50, initial_timestamp + time_delta)
    #   new_state = process_buffer(buffer, new_state)

    #   assert %{
    #            audio_levels_count: 2,
    #            audio_levels_sum: -177,
    #            vad: :silence
    #          } = new_state

    #   new_state = iterate_for(buffers: 100, volume: 0, initial: new_state, time_delta: time_delta)
    #   assert %{audio_levels_count: 101, audio_levels_sum: -50, vad: :speech} = new_state
    # end

    # test "changes between :speech and :silence based on a running average", ctx do
    #   %{
    #     time_delta: time_delta,
    #     state: state,
    #     initial_timestamp: initial_timestamp
    #   } = ctx

    #   state = process_buffer(rtp_buffer(-127, initial_timestamp), state)

    #   assert %{vad: :silence} = state

    #   new_state = iterate_for(buffers: 100, volume: 0, initial: state, time_delta: time_delta)
    #   assert %{vad: :speech} = new_state

    #   new_state = iterate_for(buffers: 5000, volume: 0, initial: state, time_delta: time_delta)
    #   assert %{audio_levels_count: 101, vad: :speech} = new_state

    #   new_state = iterate_for(buffers: 100, volume: -127, initial: state, time_delta: time_delta)
    #   assert %{audio_levels_count: 101, vad: :silence} = new_state
    # end


    # @vad_threshold -51
    # @buffer_interval 1000
    # test "transitions :silence -> :speech when avg audio level >= vad_threshold",
    #      ctx do
    #   %{
    #     time_delta: time_delta,
    #     state: state,
    #     initial_timestamp: initial_timestamp
    #   } = ctx

    #   state = process_buffer(rtp_buffer(-127, initial_timestamp), state)

    #   new_state = iterate_for(buffers: 5, volume: -50, initial: state, time_delta: time_delta)
    #   assert Enum.count(state.audio_levels) === 3
    # end


    # @min_packet_num 4
    # @vad_threshold -51
    # @buffer_interval 1000
    # test "does not transition vad mode until min_packet_num has been retained", ctx do
    #   %{
    #     time_delta: time_delta,
    #     state: state,
    #     initial_timestamp: initial_timestamp
    #   } = ctx

    #   state = process_buffer(rtp_buffer(-127, initial_timestamp), state)
    #   # assert state.vad == :silence

    #   new_state = iterate_for(buffers: 5, volume: -50, initial: state, time_delta: time_delta)
    #   assert Enum.count(state.audio_levels) === 3
    # end

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

      assert Enum.count(state.audio_levels) === 2
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

      assert Enum.count(state.audio_levels) === 2
    end

    @buffer_interval 1000
    test "ignore RTP packets that arrive out of order, from before a rollover", ctx do
      %{state: state} = ctx

      max_32bit_int = 4_294_967_295
      initial_timestamp = max_32bit_int - 5 - 1000

      state = process_buffer(rtp_buffer(-5, 995), state)
      state = process_buffer(rtp_buffer(-127, initial_timestamp + 1000), state)
      state = process_buffer(rtp_buffer(-5, 1995), state)

      assert Enum.count(state.audio_levels) === 2
    end
  end
end
