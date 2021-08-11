defmodule Membrane.RTP.SilenceDiscarder do
  @moduledoc """
  Element responsible for dropping silent audio packets.

  For a packet to be discarded it needs to contain a `RTP.HeaderExtension` struct in its
  metadata under `:rtp` key. The header should contain information about audio level (VAD extension is required).
  The element will only drop packets whose audio level equals 127 meaning muted audio.

  `#{__MODULE__}` will drop as many silent packets as possible and on reaching dropping limit it
  will reset dropped packets counter, and send `Membrane.RTP.DroppedPacketEvent` with a number of packets that have been dropped.
  The event gets sent either on reaching dropping limit or when a non-silent packet arrives.
  """
  use Membrane.Filter

  alias Membrane.RTP.Header
  alias Membrane.RTP.DroppedPacketsEvent

  require Membrane.Logger

  @max_silent_drops 1000

  @vad_id 6
  @vad_len 0
  @vad_silence_level 127

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  def_options max_consecutive_drops: [
                spec: non_neg_integer() | :infinity,
                default: @max_silent_drops,
                description: """
                A number indicating how many consecutive silent packets can be dropped before
                a single packet will be passed and dropped packet event will we emitted.

                Passing a single packets once in a while is necessary for element such as jitter buffer or encryptor as they can update their ROCs
                based on sequence numbers and when we drop to many packets we may roll it over.
                """
              ]

  @impl true
  def handle_init(opts) do
    {:ok, %{dropped: 0, max_consecutive_drops: opts.max_consecutive_drops}}
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
        %{dropped: dropped, max_consecutive_drops: max_consecutive_drops} = state
      ) do
    case buffer.metadata.rtp do
      %{
        extension: %Header.Extension{
          # profile specific for one-byte extensions
          profile_specific: <<0xBE, 0xDE>>,
          # vad extension
          data: <<@vad_id::4, @vad_len::4, _v::1, audio_level::7, 0::16>>
        }
      } ->
        cond do
          audio_level == @vad_silence_level and dropped + 1 <= max_consecutive_drops ->
            {{:ok, redemand: :output}, %{state | dropped: dropped + 1}}

          # packet can be silent but reached dropping limit so send the event and reset counter
          dropped > 0 ->
            {{:ok,
              buffer: {:output, buffer}, event: {:output, %DroppedPacketsEvent{dropped: dropped}}},
             %{state | dropped: 0}}

          true ->
            {{:ok, buffer: {:output, buffer}}, state}
        end

      _header ->
        {{:ok, buffer: {:output, buffer}}, state}
    end
  end
end
