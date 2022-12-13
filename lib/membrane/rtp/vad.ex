defmodule Membrane.RTP.VAD do
  @moduledoc """
  Simple vad based on audio level sent in RTP header.

  To make this module work appropriate RTP header extension has to be set in SDP offer/answer.

  If avg of audio level in packets in `time_window` exceeds `vad_threshold` it emits `Membrane.RTP.VadEvent`
  on its output pad.

  When avg falls below `vad_threshold` and doesn't exceed it in the next `vad_silence_timer`
  it also emits the event.

  Buffers that are processed by this element may or may not have been processed by
  a depayloader and passed through a jitter buffer. If they have not, then the only timestamp
  available for time comparison is the RTP timestamp. The delta between RTP timestamps is
  dependent on the clock rate used by the encoding. For `OPUS` the clock rate is `48kHz` and
  packets are sent every `20ms`, so the RTP timestamp delta between sequential packets should
  be `48000 / 1000 * 20`, or `960`.

  When calculating the epoch of the timestamp, we need to account for 32bit integer wrapping.
  * `:current` - the difference between timestamps is low: the timestamp has not wrapped around.
  * `:next` - the timestamp has wrapped around to 0. To simplify queue processing we reset the state.
  * `:prev` - the timestamp has recently wrapped around. We might receive an out-of-order packet
    from before the rollover, which we ignore.
  """
  use Membrane.Filter

  alias Membrane.RTP.{Header, Utils, VadEvent}

  def_input_pad :input, availability: :always, accepted_format: _any, demand_mode: :auto

  def_output_pad :output, availability: :always, accepted_format: _any, demand_mode: :auto

  def_options vad_id: [
                spec: 1..14,
                description: "ID of VAD header extension."
              ],
              clock_rate: [
                spec: Membrane.RTP.clock_rate_t(),
                default: 48_000,
                description: "Clock rate (in `Hz`) for the encoding."
              ],
              time_window: [
                spec: pos_integer(),
                default: 2_000,
                description: "Time window (in `ms`) in which avg audio level is measured."
              ],
              min_packet_num: [
                spec: pos_integer(),
                default: 50,
                description: """
                Minimal number of packets to count avg audio level from.
                Speech won't be detected until there are enough packets.
                """
              ],
              vad_threshold: [
                spec: -127..0,
                default: -50,
                description: """
                Audio level in dBov representing vad threshold.
                Values above are considered to represent voice activity.
                Value -127 represents digital silence.
                """
              ],
              vad_silence_time: [
                spec: pos_integer(),
                default: 300,
                description: """
                Time to wait before emitting `Membrane.RTP.VadEvent` after audio track is
                no longer considered to represent speech.
                If at this time audio track is considered to represent speech again the event will not be sent.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      vad_id: opts.vad_id,
      audio_levels: Qex.new(),
      clock_rate: opts.clock_rate,
      vad: :silence,
      vad_silence_timestamp: 0,
      current_timestamp: nil,
      rtp_timestamp_increment: opts.time_window * opts.clock_rate / 1000,
      min_packet_num: opts.min_packet_num,
      time_window: opts.time_window,
      vad_threshold: opts.vad_threshold,
      vad_silence_time: opts.vad_silence_time,
      audio_levels_sum: 0,
      audio_levels_count: 0
    }

    {[], state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    {extension, buffer} = Header.Extension.pop(buffer, state.vad_id)
    handle_if_present(buffer, extension, state)
  end

  defp handle_if_present(buffer, nil, state), do: {[buffer: {:output, buffer}], state}

  @timestamp_limit Bitwise.bsl(1, 32)

  defp handle_if_present(buffer, extension, state) do
    <<_v::1, level::7>> = extension.data

    new_extension = %Header.Extension{
      identifier: :vad,
      data: extension.data
    }

    buffer = Header.Extension.put(buffer, new_extension)

    rtp_timestamp = buffer.metadata.rtp.timestamp
    rollover = Utils.from_which_rollover(state.current_timestamp, rtp_timestamp, @timestamp_limit)
    current_timestamp = state.current_timestamp || 0

    cond do
      rollover == :current && rtp_timestamp > current_timestamp ->
        handle_vad(buffer, rtp_timestamp, level, state)

      rollover == :next ->
        {[], state} = handle_init(%{}, state)
        {[buffer: {:output, buffer}], state}

      true ->
        {[buffer: {:output, buffer}], state}
    end
  end

  defp handle_vad(buffer, rtp_timestamp, level, state) do
    state = %{state | current_timestamp: rtp_timestamp}
    state = filter_old_audio_levels(state)
    state = add_new_audio_level(state, level)
    audio_levels_vad = get_audio_levels_vad(state)
    actions = [buffer: {:output, buffer}] ++ maybe_send_event(audio_levels_vad, state)
    state = update_vad_state(audio_levels_vad, state)
    {{:ok, actions}, state}
  end

  defp filter_old_audio_levels(state) do
    Enum.reduce_while(state.audio_levels, state, fn {level, timestamp}, state ->
      if Ratio.sub(state.current_timestamp, timestamp)
         |> Ratio.gt?(state.rtp_timestamp_increment) do
        {_level, audio_levels} = Qex.pop(state.audio_levels)

        state = %{
          state
          | audio_levels_sum: state.audio_levels_sum - level,
            audio_levels_count: state.audio_levels_count - 1,
            audio_levels: audio_levels
        }

        {:cont, state}
      else
        {:halt, state}
      end
    end)
  end

  defp add_new_audio_level(state, level) do
    audio_levels = Qex.push(state.audio_levels, {-level, state.current_timestamp})

    %{
      state
      | audio_levels: audio_levels,
        audio_levels_sum: state.audio_levels_sum + -level,
        audio_levels_count: state.audio_levels_count + 1
    }
  end

  defp get_audio_levels_vad(state) do
    if state.audio_levels_count >= state.min_packet_num and avg(state) >= state.vad_threshold,
      do: :speech,
      else: :silence
  end

  defp avg(state), do: state.audio_levels_sum / state.audio_levels_count

  defp maybe_send_event(audio_levels_vad, state) do
    if vad_silence?(audio_levels_vad, state) or vad_speech?(audio_levels_vad, state) do
      [event: {:output, %VadEvent{vad: audio_levels_vad}}]
    else
      []
    end
  end

  defp update_vad_state(audio_levels_vad, state) do
    cond do
      vad_maybe_silence?(audio_levels_vad, state) ->
        Map.merge(state, %{vad: :maybe_silence, vad_silence_timestamp: state.current_timestamp})

      vad_silence?(audio_levels_vad, state) or vad_speech?(audio_levels_vad, state) ->
        Map.merge(state, %{vad: audio_levels_vad})

      true ->
        state
    end
  end

  defp vad_silence?(audio_levels_vad, state),
    do: state.vad == :maybe_silence and audio_levels_vad == :silence and timer_expired?(state)

  defp vad_speech?(audio_levels_vad, state) do
    (state.vad == :maybe_silence and audio_levels_vad == :speech) or
      (state.vad == :silence and audio_levels_vad == :speech)
  end

  defp vad_maybe_silence?(audio_levels_vad, state),
    do: state.vad == :speech and audio_levels_vad == :silence

  defp timer_expired?(state),
    do: state.current_timestamp - state.vad_silence_timestamp > state.vad_silence_time
end
