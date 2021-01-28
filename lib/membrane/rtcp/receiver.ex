defmodule Membrane.RTCP.Receiver do
  use Membrane.Filter

  alias Membrane.RTCPEvent
  alias Membrane.RTCP.FeedbackPacket

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any

  def_options local_ssrc: [], remote_ssrc: []

  @impl true
  def handle_init(opts) do
    {:ok, Map.from_struct(opts) |> Map.merge(%{fir_seq_num: 0})}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_event(:output, %Membrane.KeyframeRequestEvent{}, _ctx, state) do
    packet = %FeedbackPacket{
      origin_ssrc: state.local_ssrc,
      payload: %FeedbackPacket.FIR{
        target_ssrc: state.remote_ssrc,
        seq_num: state.fir_seq_num
      }
    }

    event = %RTCPEvent{packet: packet}
    state = Map.update!(state, :fir_seq_num, &(&1 + 1))
    {{:ok, event: {:input, event}}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)
end
