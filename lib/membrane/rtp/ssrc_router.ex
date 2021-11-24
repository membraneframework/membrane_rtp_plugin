defmodule Membrane.RTP.SSRCRouter do
  @moduledoc """
  A filter separating RTP packets from different SSRCs into different outpts.

  When receiving a new SSRC, it creates a new pad and notifies its parent (`t:new_stream_notification_t/0`) that should link
  the new output pad.

  When an RTCP event arrives from some output pad the router tries to forward it do a proper input pad.
  The input pad gets chosen by the source input pad from which packets with given ssrc were previously sent,
  the source pad's id gets extracted and the router tries to send the event to an input
  pad of id `{:rtcp, id}`, if no such pad exists the router simply drops the event.
  """

  use Membrane.Filter

  alias Membrane.{RTP, RTCPEvent}

  def_input_pad :input, demand_unit: :buffers, caps: RTP, availability: :on_request

  def_output_pad :output, caps: RTP, availability: :on_request

  defmodule State do
    @moduledoc false
    use Bunch.Access

    alias Membrane.RTP

    @type t() :: %__MODULE__{
            pads: %{RTP.ssrc_t() => [input_pad :: Pad.ref_t()]},
            linking_buffers: %{RTP.ssrc_t() => [Membrane.Buffer.t()]},
            handshake_event: struct() | nil
          }

    defstruct pads: %{},
              linking_buffers: %{},
              handshake_event: nil
  end

  @typedoc """
  Notification sent when an RTP packet with new SSRC arrives and new output pad should be linked
  """
  @type new_stream_notification_t ::
          {:new_rtp_stream, RTP.ssrc_t(), RTP.payload_type_t(), [RTP.Header.Extension.t()]}

  @impl true
  def handle_init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    {buffered_actions, state} = pop_in(state, [:linking_buffers, ssrc])

    events =
      if state.handshake_event do
        [{:event, {pad, state.handshake_event}}]
      else
        []
      end

    {{:ok, [caps: {pad, %RTP{}}] ++ events ++ Enum.reverse(buffered_actions)}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state) do
    new_pads =
      state.pads
      |> Enum.filter(fn {_ssrc, p} -> p != pad end)
      |> Enum.into(%{})

    {:ok, %State{state | pads: new_pads}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, _ssrc), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    actions =
      ctx.pads
      |> Enum.filter(fn {_pad_ref, pad_data} -> pad_data.direction == :input end)
      |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, ssrc), _size, _unit, ctx, state) do
    input_pad = state.pads[ssrc]
    {{:ok, demand: {input_pad, &(&1 + ctx.incoming_demand)}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, _ctx, state) do
    %Membrane.Buffer{
      metadata: %{rtp: %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}}
    } = buffer

    {new_stream_actions, state} =
      maybe_handle_new_stream(pad, ssrc, payload_type, extensions, state)

    {actions, state} = maybe_add_to_linking_buffer(:buffer, buffer, ssrc, state)
    {{:ok, new_stream_actions ++ actions}, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), %RTCPEvent{} = event, _ctx, state) do
    {actions, state} =
      event.ssrcs
      |> Enum.filter(&Map.has_key?(state.pads, &1))
      |> Enum.flat_map_reduce(state, fn ssrc, state ->
        maybe_add_to_linking_buffer(:event, event, ssrc, state)
      end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(_pad, %{handshake_data: _data} = event, _ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.pads, state, fn {ssrc, _input}, state ->
        maybe_add_to_linking_buffer(:event, event, ssrc, state)
      end)

    {{:ok, actions}, %{state | handshake_event: event}}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), event, _ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.pads, state, fn {ssrc, _input}, state ->
        maybe_add_to_linking_buffer(:event, event, ssrc, state)
      end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(Pad.ref(:output, ssrc), %RTCPEvent{} = event, ctx, state) do
    with {:ok, Pad.ref(:input, id)} <- Map.fetch(state.pads, ssrc),
         rtcp_pad = Pad.ref(:input, {:rtcp, id}),
         true <- Map.has_key?(ctx.pads, rtcp_pad) do
      {{:ok, event: {rtcp_pad, event}}, state}
    else
      :error ->
        {:ok, state}

      # rtcp pad not found
      false ->
        {:ok, state}
    end
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  defp maybe_handle_new_stream(pad, ssrc, payload_type, extensions, state) do
    if Map.has_key?(state.pads, ssrc) do
      {[], state}
    else
      state = state |> put_in([:pads, ssrc], pad) |> put_in([:linking_buffers, ssrc], [])

      {[notify: {:new_rtp_stream, ssrc, payload_type, extensions}], state}
    end
  end

  defp maybe_add_to_linking_buffer(type, value, ssrc, state) do
    action = {type, {Pad.ref(:output, ssrc), value}}

    if waiting_for_linking?(ssrc, state) do
      state = update_in(state, [:linking_buffers, ssrc], &[action | &1])
      actions = if type == :buffer, do: [demand: {state.pads[ssrc], &(&1 + 1)}], else: []
      {actions, state}
    else
      {[action], state}
    end
  end

  defp waiting_for_linking?(ssrc, %State{linking_buffers: lb}), do: Map.has_key?(lb, ssrc)
end
