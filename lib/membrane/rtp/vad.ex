defmodule Membrane.RTP.VAD do
  @moduledoc """
  Vad based on audio level sent in RTP header.

  To make this module work appropriate RTP header extension has to be set in SDP offer/answer.

  This module is responsible for:
    - receiving the RTP headers with audio levels in range [-127, 0] dBov
    - calculating the epoch of the timestamp
    - storing them in a queue
    - asking the IsSpeakingEstimator if the audio levels indicate speech or silence
    - emitting the VAD event if the estimation has changed


  The more detailed explanation of how the VAD algorithm can be found in the IsSpeakingEstimator module

  Buffers that are processed by this element may or may not have been processed by
  a depayloader and passed through a jitter buffer. If they have not, then the only timestamp
  available for time comparison is the RTP timestamp.

  When calculating the epoch of the timestamp, we need to account for 32bit integer wrapping.
  * `:current` - the difference between timestamps is low: the timestamp has not wrapped around.
  * `:next` - the timestamp has wrapped around to 0. To simplify queue processing we reset the state.
  * `:prev` - the timestamp has recently wrapped around. We might receive an out-of-order packet
    from before the rollover, which we ignore.
  """
  use Membrane.Filter

  alias Membrane.RTP.{Header, Utils, VadEvent}
  alias Membrane.RTP.VadUtils.IsSpeakingEstimator

  def_input_pad :input, availability: :always, accepted_format: _any, demand_mode: :auto

  def_output_pad :output, availability: :always, accepted_format: _any, demand_mode: :auto

  def_options vad_id: [
                spec: 1..14,
                description: "ID of VAD header extension."
              ],
              vad_threshold: [
                spec: -127..0,
                default: -32,
                description: """
                Audio level in dBov representing vad threshold.
                Values above are considered to represent voice activity.
                Value -127 represents digital silence.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      vad_id: opts.vad_id,
      audio_levels: Qex.new(),
      target_audio_levels_length: IsSpeakingEstimator.target_levels_length(),
      vad: :silence,
      current_timestamp: nil,
      vad_threshold: opts.vad_threshold + 127
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
    state = add_new_audio_level(state, level)

    {trimmed_queue, audio_levels_vad} =
      trim_queue_and_estimate_vad(
        state.audio_levels,
        state.vad_threshold,
        state.target_audio_levels_length
      )

    state = %{state | audio_levels: trimmed_queue}
    actions = [buffer: {:output, buffer}] ++ maybe_send_event(audio_levels_vad, state)
    state = update_vad_state(audio_levels_vad, state)
    {actions, state}
  end

  defp add_new_audio_level(state, level) do
    audio_levels = Qex.push_front(state.audio_levels, {127 - level, state.current_timestamp})

    %{state | audio_levels: audio_levels}
  end

  # Takes the queue from RTP VAD module and returns the queue of `target_audio_levels_length` length and the estimation
  defp trim_queue_and_estimate_vad(queue, threshold, levels_length) do
    trimmed_queue = safe_trim_queue(queue, levels_length)

    estimation =
      trimmed_queue
      |> Enum.map(fn {level, _timestamp} -> level end)
      |> IsSpeakingEstimator.estimate_is_speaking(threshold)

    {trimmed_queue, estimation}
  end

  @spec safe_trim_queue(Qex.t(), integer) :: Qex.t()
  defp safe_trim_queue(queue, n) do
    if Enum.count(queue) > n do
      {trimmed_queue, _rest} = Qex.split(queue, n)
      trimmed_queue
    else
      queue
    end
  end

  defp maybe_send_event(audio_levels_vad, state) do
    if vad_state_has_changed(state.vad, audio_levels_vad) do
      [event: {:output, %VadEvent{vad: audio_levels_vad}}]
    else
      []
    end
  end

  defp update_vad_state(audio_levels_vad, state), do: %{state | vad: audio_levels_vad}

  defp vad_state_has_changed(old_value, new_value), do: old_value != new_value
end
