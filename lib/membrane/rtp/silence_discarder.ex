defmodule Membrane.RTP.SilenceDiscarder do
  @moduledoc """
  Element responsible for dropping silent audio packets.

  For a packet to be discarded it needs to contain a `RTP.Header` struct in its
  metadata (packet should be inspected by `RTP.PreParser` to parse the header
  without changing the packet itself) and a vad extension must be enabled.
  The element will drop every packet whose audio level equals 127 meaning synthetic silence.

  `#{__MODULE__}` does not know anything about incoming packets, it does not check for
  their ssrcs (therefore just a single audio stream should be passed via single
  SilenceDiscarder instance), it just checks for the header and if the vad
  extension is present it will drop as many consecutive silence packets as possible
  (until reaching max_consecutive_drops, then it will pass a single packet
  and reset the counter).
  """
  use Membrane.Filter

  alias Membrane.RTP.Header

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
                a single packet will be passed.

                Passing single packets is beneficial for element such as jitter buffer or encryptor as they can update their ROCs.
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
          audio_level == @vad_silence_level and dropped + 1 < max_consecutive_drops ->
            {{:ok, redemand: :output}, %{state | dropped: dropped + 1}}

          # packet is silent but we exceeded max_consecutive_drops
          audio_level == @vad_silence_level ->
            Membrane.Logger.debug("Resetting dropped packets counter")
            {{:ok, buffer: {:output, buffer}}, %{state | dropped: 0}}

          true ->
            {{:ok, buffer: {:output, buffer}}, state}
        end

      _ ->
        {{:ok, buffer: {:output, buffer}}, state}
    end
  end
end
