defmodule Membrane.RTP.SilenceDiscarder do
  use Membrane.Filter

  alias Membrane.RTP.{DiscardedPacket, Header}

  require Membrane.Logger

  @max_silent_drops 50

  @vad_id 6
  @vad_len 0
  @vad_silence_level 127

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  @impl true
  def handle_init(_opts) do
    {:ok, %{silent_drops: 0}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  def handle_process(:input, buffer, _ctx, %{silent_drops: silent_drops} = state) do
    # try sending every 10th discarded packet to limit message passing and copying between processes
    case buffer.metadata do
      %Header{
        extension: %Header.Extension{
          # profile specific for one-byte extensions
          profile_specific: <<0xBE, 0xDE>>,
          # vad extension
          data: <<@vad_id::4, @vad_len::4, _v::1, @vad_silence_level::7, 0::16>>
        }
      } = header ->
        if silent_drops + 1 > @max_silent_drops do
          {{:ok, event: {:output, %DiscardedPacket{header: header}}}, %{state | silent_drops: 0}}
        else
          {:ok, %{state | silent_drops: silent_drops + 1}}
        end

      # {{:ok, event: {:output, %DiscardedPacket{header: header}}}, state}
      _ ->
        {{:ok, buffer: {:output, buffer}}, state}
    end
  end
end
