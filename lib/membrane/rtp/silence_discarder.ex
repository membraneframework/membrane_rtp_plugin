defmodule Membrane.RTP.SilenceDiscarder do
  @moduledoc """
  Element responsible for dropping silent audio packets.

  For a packet to be discarded it needs to contain a `RTP.HeaderExtension` struct in its
  metadata under `:rtp` key. The header should contain information about audio level (VAD extension is required).
  The element will only drop packets whose audio level is above given silence threshold (muted audio is of value 127).

  `#{__MODULE__}` will drop as many silent packets as possible and on reaching dropping limit it will send the current buffer,
  reset dropped packets counter and emit `Membrane.RTP.DroppedPacketEvent` with a number of packets that have been dropped until that point.
  The event gets sent on both reaching dropping limit and when a non-silent packet arrives.
  """
  use Membrane.Filter

  alias Membrane.RTP.Header
  alias Membrane.RTP.PacketsDroppedEvent

  require Membrane.Logger

  @vad_len 0

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  def_options max_consecutive_drops: [
                spec: non_neg_integer() | :infinity,
                default: 1000,
                description: """
                A number indicating how many consecutive silent packets can be dropped before
                a single packet will be passed and dropped packet event will we emitted.

                Passing a single packets once in a while is necessary for element such as jitter buffer or encryptor as they can update their ROCs
                based on sequence numbers and when we drop to many packets we may roll it over.
                """
              ],
              silence_threshold: [
                spec: 1..127,
                default: 127,
                description: """
                Audio level threshold that will be compared against incoming packets. Packet will be dropped if its audio level
                is above or equal to the given threshold.
                """
              ],
              vad_id: [
                spec: 1..14,
                default: 6,
                description: """
                ID of a VAD extension.
                """
              ]

  @impl true
  def handle_init(opts) do
    {:ok, Map.from_struct(opts) |> Map.put(:dropped, 0)}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_event(pad, other, ctx, state), do: super(pad, other, ctx, state)

  @impl true
  def handle_process(:input, _buffer, _ctx, %{max_consecutive_drops: :infinite} = state) do
    {:ok, state}
  end

  @impl true
  def handle_process(
        :input,
        buffer,
        _ctx,
        %{dropped: dropped, max_consecutive_drops: max_drops} = state
      )
      when dropped == max_drops do
    stop_dropping(buffer, state)
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    %{dropped: dropped, vad_id: vad_id, silence_threshold: silence_threshold} = state

    case buffer.metadata.rtp do
      %{
        extension: %Header.Extension{
          # profile specific for one-byte extensions
          profile_specific: <<0xBE, 0xDE>>,
          data: data
        }
      } ->
        silent? = is_silent_packet(vad_id, silence_threshold, data)

        cond do
          silent? ->
            {{:ok, redemand: :output}, %{state | dropped: dropped + 1}}

          dropped > 0 ->
            stop_dropping(buffer, state)

          true ->
            {{:ok, buffer: {:output, buffer}}, state}
        end

      _header ->
        {{:ok, buffer: {:output, buffer}}, state}
    end
  end

  defp stop_dropping(buffer, state) do
    {{:ok,
      event: {:output, %PacketsDroppedEvent{dropped: state.dropped}}, buffer: {:output, buffer}},
     %{state | dropped: 0}}
  end

  defp is_silent_packet(_vad_id, _threshold, <<>>), do: false

  # vad extension
  defp is_silent_packet(
         vad_id,
         threshold,
         <<vad_id::4, @vad_len::4, _v::1, audio_level::7, _rest::binary>>
       ) do
    audio_level >= threshold
  end

  # extension padding
  defp is_silent_packet(vad_id, threshold, <<0::8, rest::binary>>),
    do: is_silent_packet(vad_id, threshold, rest)

  # unknown extension
  defp is_silent_packet(
         vad_id,
         threshold,
         <<_id::4, len::4, _data0::8, _data1::binary-size(len), rest::binary>>
       ),
       do: is_silent_packet(vad_id, threshold, rest)
end
