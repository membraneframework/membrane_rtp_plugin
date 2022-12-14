defmodule Membrane.RTP.SSRCRouter do
  @moduledoc """
  A filter separating RTP packets from different SSRCs into different outpts.

  When receiving a new SSRC, it creates a new pad and notifies its parent (`t:new_stream_notification_t/0`) that should link
  the new output pad.

  When an RTCP event arrives from some output pad the router tries to forward it to a proper input pad.
  The input pad gets chosen by the source input pad from which packets with given ssrc were previously sent,
  the source pad's id gets extracted and the router tries to send the event to an input
  pad of id `{:input, id}`, if no such pad exists the router simply drops the event.
  """

  use Membrane.Filter

  require Membrane.Logger
  require Membrane.TelemetryMetrics

  alias __MODULE__.RequireExtensions
  alias Membrane.{RTCP, RTCPEvent, RTP, SRTP}

  @packet_arrival_event [Membrane.RTP, :packet, :arrival]
  @new_inbound_track_event [Membrane.RTP, :inbound_track, :new]

  def_input_pad :input,
    accepted_format: any_of(RTCP, RTP),
    availability: :on_request,
    demand_mode: :auto

  def_output_pad :output,
    accepted_format: RTP,
    availability: :on_request,
    demand_mode: :auto,
    options: [
      telemetry_label: [
        spec: Membrane.TelemetryMetrics.label(),
        default: []
      ],
      encoding: [
        spec: atom() | nil,
        default: nil
      ]
    ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    alias Membrane.RTP

    @type t() :: %__MODULE__{
            input_pads: %{RTP.ssrc_t() => [input_pad :: Pad.ref_t()]},
            buffered_actions: %{RTP.ssrc_t() => [Membrane.Element.Action.t()]},
            required_extensions: %{
              RTP.payload_type_t() => MapSet.t(RTP.Header.Extension.identifier_t())
            },
            srtp_keying_material_event: struct() | nil
          }

    defstruct input_pads: %{},
              buffered_actions: %{},
              required_extensions: %{},
              srtp_keying_material_event: nil
  end

  @typedoc """
  Notification sent when an RTP packet with new SSRC arrives and new output pad should be linked
  """
  @type new_stream_notification_t ::
          {:new_rtp_stream, RTP.ssrc_t(), RTP.payload_type_t(), [RTP.Header.Extension.t()]}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %State{}}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _id) = pad, ctx, state) do
    # multiple SSRCs might come from single input pad
    {actions, state} =
      state.input_pads
      |> Enum.filter(fn {_ssrc, p} -> p == pad end)
      |> Enum.flat_map_reduce(state, fn {ssrc, _pad}, state ->
        action = {:end_of_stream, Pad.ref(:output, ssrc)}
        maybe_buffer_action(action, ssrc, ctx, state)
      end)

    {actions, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, ctx, state) do
    {buffered_actions, state} = pop_in(state, [:buffered_actions, ssrc])
    buffered_actions = Enum.reverse(buffered_actions || [])

    register_packet_arrival_event(pad, ctx)
    emit_packet_arrival_events(buffered_actions, ctx)

    register_new_inbound_track_event(pad, ctx)
    emit_new_inbound_track_event(ssrc, pad, ctx)

    events =
      if state.srtp_keying_material_event do
        [{:event, {pad, state.srtp_keying_material_event}}]
      else
        []
      end

    {[stream_format: {pad, %RTP{}}] ++ events ++ buffered_actions, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state) do
    new_pads =
      state.input_pads
      |> Enum.filter(fn {_ssrc, p} -> p != pad end)
      |> Enum.into(%{})

    {[], %State{state | input_pads: new_pads}}
  end

  @impl true
  def handle_pad_removed(pad, ctx, state), do: super(pad, ctx, state)

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, ctx, state) do
    %Membrane.Buffer{
      metadata: %{
        rtp: %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}
      }
    } = buffer

    {new_stream_actions, state} =
      maybe_handle_new_stream(pad, ssrc, payload_type, extensions, state)

    action = {:buffer, {Pad.ref(:output, ssrc), buffer}}
    {actions, state} = maybe_buffer_action(action, ssrc, ctx, state)
    emit_packet_arrival_events(actions, ctx)

    {new_stream_actions ++ actions, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), %RTCPEvent{} = event, ctx, state) do
    actions =
      event.ssrcs
      |> Enum.flat_map(fn ssrc ->
        target_pad = Pad.ref(:output, ssrc)

        if Map.has_key?(ctx.pads, target_pad) do
          [event: {target_pad, event}]
        else
          # TODO: This should most likely be a warning, however it appears on every join and leave,
          # So until it's fixed, it is reported with debug log level
          Membrane.Logger.debug("Received event (#{inspect(event)}) for unknown SSRC: #{ssrc}")
          []
        end
      end)

    {actions, state}
  end

  @impl true
  def handle_event(_pad, %SRTP.KeyingMaterialEvent{} = event, ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.input_pads, state, fn {ssrc, _input}, state ->
        action = {:event, {Pad.ref(:output, ssrc), event}}
        maybe_buffer_action(action, ssrc, ctx, state)
      end)

    {actions, %{state | srtp_keying_material_event: event}}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), event, ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.input_pads, state, fn {ssrc, _input}, state ->
        action = {:event, {Pad.ref(:output, ssrc), event}}
        maybe_buffer_action(action, ssrc, ctx, state)
      end)

    {actions, state}
  end

  @impl true
  def handle_event(Pad.ref(:output, ssrc), %RTCPEvent{} = event, ctx, state) do
    with {:ok, Pad.ref(:input, id)} <- Map.fetch(state.input_pads, ssrc),
         rtcp_pad = Pad.ref(:input, {:rtcp, id}),
         true <- Map.has_key?(ctx.pads, rtcp_pad) do
      {[event: {rtcp_pad, event}], state}
    else
      :error ->
        {[], state}

      # rtcp pad not found
      false ->
        {[], state}
    end
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_parent_notification(%RequireExtensions{pt_to_ext_id: pt_to_ext_id}, _ctx, state) do
    pt_to_ext_id = Map.new(pt_to_ext_id, fn {pt, ids} -> {pt, MapSet.new(ids)} end)

    required_extensions =
      Map.merge(state.required_extensions, pt_to_ext_id, fn _pt, set, ext_ids ->
        MapSet.union(set, ext_ids)
      end)

    {[], %{state | required_extensions: required_extensions}}
  end

  defp maybe_handle_new_stream(pad, ssrc, payload_type, extensions, state) do
    required_extensions = Map.get(state.required_extensions, payload_type, MapSet.new())

    cond do
      Map.has_key?(state.input_pads, ssrc) ->
        {[], state}

      Map.has_key?(state.required_extensions, payload_type) and
          not MapSet.subset?(required_extensions, MapSet.new(extensions, & &1.identifier)) ->
        Membrane.Logger.debug("""
        Dropping packet of SSRC #{ssrc} without required extension(s).
        Required: #{inspect(required_extensions)}, present: #{inspect(extensions)}
        """)

        {[], state}

      true ->
        state =
          state
          |> put_in([:input_pads, ssrc], pad)
          |> put_in([:buffered_actions, ssrc], [])

        {[notify_parent: {:new_rtp_stream, ssrc, payload_type, extensions}], state}
    end
  end

  defp maybe_buffer_action(action, ssrc, ctx, state) do
    if linked?(ssrc, ctx) do
      {[action], state}
    else
      state = update_in(state, [:buffered_actions, ssrc], &[action | &1])
      {[], state}
    end
  end

  defp emit_packet_arrival_events(actions, ctx) do
    for action <- actions do
      with {:buffer, {pad, buffer}} <- action do
        emit_packet_arrival_event(buffer.payload, pad, ctx)
      end
    end
  end

  defp register_packet_arrival_event(pad, ctx) do
    Membrane.TelemetryMetrics.register(
      @packet_arrival_event,
      ctx.pads[pad].options.telemetry_label
    )
  end

  defp register_new_inbound_track_event(pad, ctx) do
    Membrane.TelemetryMetrics.register(
      @new_inbound_track_event,
      ctx.pads[pad].options.telemetry_label
    )
  end

  defp emit_packet_arrival_event(payload, pad, ctx) do
    Membrane.TelemetryMetrics.execute(
      @packet_arrival_event,
      %{bytes: byte_size(payload)},
      %{},
      ctx.pads[pad].options.telemetry_label
    )
  end

  defp emit_new_inbound_track_event(ssrc, pad, ctx) do
    Membrane.TelemetryMetrics.execute(
      @new_inbound_track_event,
      %{ssrc: ssrc} |> maybe_add_encoding(pad, ctx),
      %{},
      ctx.pads[pad].options.telemetry_label
    )
  end

  defp maybe_add_encoding(measurements, pad, ctx) do
    case ctx.pads[pad].options.encoding do
      nil -> measurements
      encoding -> Map.put(measurements, :encoding, encoding)
    end
  end

  defp linked?(ssrc, ctx), do: Map.has_key?(ctx.pads, Pad.ref(:output, ssrc))
end
