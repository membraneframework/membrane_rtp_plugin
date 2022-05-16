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

  require Membrane.TelemetryMetrics

  def_input_pad :input, caps: RTP, availability: :on_request, demand_mode: :auto

  def_input_pad :rtcp_input, caps: :any, availability: :on_request, demand_mode: :auto

  def_output_pad :output,
    caps: RTP,
    availability: :on_request,
    demand_mode: :auto,
    options: [
      keyframe_detector: [
        spec: function() | nil,
        default: nil
      ],
      frame_detector: [
        spec: function() | nil,
        default: nil
      ],
      telemetry_metadata: [
        spec: [{atom(), atom()}],
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
            output_pad_ids: MapSet.t(),
            linking_buffers: %{RTP.ssrc_t() => [Membrane.Buffer.t()]},
            handshake_event: struct() | nil,
            ssrc_to_keyframe_detector: %{RTP.ssrc_t() => function() | nil},
            ssrc_to_frame_detector: %{RTP.ssrc_t() => function() | nil}
          }

    defstruct input_pads: %{},
              output_pad_ids: MapSet.new(),
              linking_buffers: %{},
              handshake_event: nil,
              ssrc_to_keyframe_detector: %{},
              ssrc_to_frame_detector: %{}
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
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, ctx, state) do
    keyframe_detector = ctx.pads[pad].options.keyframe_detector
    frame_detector = ctx.pads[pad].options.frame_detector
    {buffered_actions, state} = pop_in(state, [:linking_buffers, ssrc])
    buffered_actions = Enum.reverse(buffered_actions || [])

    maybe_emit_telemetry_events(buffered_actions, state, ctx)

    events =
      if state.handshake_event do
        [{:event, {pad, state.handshake_event}}]
      else
        []
      end

    state =
      state
      |> Map.update!(
        :ssrc_to_keyframe_detector,
        &Map.put(&1, ssrc, keyframe_detector)
      )
      |> Map.update!(
        :ssrc_to_frame_detector,
        &Map.put(&1, ssrc, frame_detector)
      )

    {{:ok, [caps: {pad, %RTP{}}] ++ events ++ buffered_actions},
     %State{state | output_pad_ids: MapSet.put(state.output_pad_ids, ssrc)}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state) do
    new_pads =
      state.input_pads
      |> Enum.filter(fn {_ssrc, p} -> p != pad end)
      |> Enum.into(%{})

    {:ok, %State{state | input_pads: new_pads}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, ssrc), _ctx, state) do
    {:ok, %State{state | output_pad_ids: MapSet.delete(state.output_pad_ids, ssrc)}}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, ctx, state) do
    %Membrane.Buffer{
      metadata: %{rtp: %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}}
    } = buffer

    {new_stream_actions, state} =
      maybe_handle_new_stream(pad, ssrc, payload_type, extensions, state)

    {actions, state} = maybe_add_to_linking_buffer(:buffer, buffer, ssrc, state)
    maybe_emit_telemetry_events(actions, state, ctx)

    {{:ok, new_stream_actions ++ actions}, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), %RTCPEvent{} = event, _ctx, state) do
    actions =
      event.ssrcs
      |> Enum.filter(&MapSet.member?(state.output_pad_ids, &1))
      |> Enum.map(&{:event, {Pad.ref(:output, &1), event}})

    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(_pad, %{handshake_data: _data} = event, _ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.input_pads, state, fn {ssrc, _input}, state ->
        maybe_add_to_linking_buffer(:event, event, ssrc, state)
      end)

    {{:ok, actions}, %{state | handshake_event: event}}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), event, _ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.input_pads, state, fn {ssrc, _input}, state ->
        maybe_add_to_linking_buffer(:event, event, ssrc, state)
      end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(Pad.ref(:output, ssrc), %RTCPEvent{} = event, ctx, state) do
    with {:ok, Pad.ref(:input, id)} <- Map.fetch(state.input_pads, ssrc),
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
    if Map.has_key?(state.input_pads, ssrc) do
      {[], state}
    else
      state =
        state
        |> put_in([:input_pads, ssrc], pad)
        |> put_in([:linking_buffers, ssrc], [])

      {[notify: {:new_rtp_stream, ssrc, payload_type, extensions}], state}
    end
  end

  defp maybe_add_to_linking_buffer(type, value, ssrc, state) do
    action = {type, {Pad.ref(:output, ssrc), value}}

    if waiting_for_linking?(ssrc, state) do
      state = update_in(state, [:linking_buffers, ssrc], &[action | &1])
      {[], state}
    else
      {[action], state}
    end
  end

  defp waiting_for_linking?(ssrc, %State{linking_buffers: lb}), do: Map.has_key?(lb, ssrc)

  defp maybe_emit_telemetry_events(actions, state, ctx) do
    for action <- actions do
      with {:buffer, {pad, buffer}} <- action do
        emit_packet_arrival_event(buffer.metadata.rtp.ssrc, buffer.payload, pad, state, ctx)
      end
    end
  end

  defp emit_packet_arrival_event(ssrc, payload, pad, state, ctx) do
    Membrane.TelemetryMetrics.execute(
      [:packet_arrival, :rtp],
      packet_arrival_telemetry_measurements(ssrc, payload, pad, state, ctx),
      %{ssrc: ssrc, telemetry_metadata: ctx.pads[pad].options.telemetry_metadata}
    )
  end

  defp packet_arrival_telemetry_measurements(ssrc, payload, pad, state, ctx) do
    %{bytes: byte_size(payload)}
    |> maybe_add_keyframe_indicator(ssrc, payload, state)
    |> maybe_add_frame_indicator(ssrc, payload, state)
    |> maybe_add_encoding(pad, ctx)
  end

  defp maybe_add_keyframe_indicator(measurements, ssrc, payload, state) do
    detector = state.ssrc_to_keyframe_detector[ssrc]

    cond do
      detector == nil -> measurements
      detector.(payload) -> Map.put(measurements, :keyframe_indicator, 1)
      true -> Map.put(measurements, :keyframe_indicator, 0)
    end
  end

  defp maybe_add_frame_indicator(measurements, ssrc, payload, state) do
    detector = state.ssrc_to_frame_detector[ssrc]

    cond do
      detector == nil -> measurements
      detector.(payload) -> Map.put(measurements, :frame_indicator, 1)
      true -> Map.put(measurements, :frame_indicator, 0)
    end
  end

  defp maybe_add_encoding(measurements, pad, ctx) do
    case ctx.pads[pad].options.encoding do
      nil -> measurements
      encoding -> Map.put(measurements, :encoding, encoding)
    end
  end
end
