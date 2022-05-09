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

  alias Membrane.{RTP, RTCPEvent, SRTP}

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
            ssrc_to_keyframe_detector: %{RTP.ssrc_t() => function() | nil},
            ssrc_to_frame_detector: %{RTP.ssrc_t() => function() | nil},
            srtp_keying_material_event: struct() | nil
          }

    defstruct input_pads: %{},
              output_pad_ids: MapSet.new(),
              linking_buffers: %{},
              ssrc_to_keyframe_detector: %{},
              ssrc_to_frame_detector: %{},
              srtp_keying_material_event: nil
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

    events =
      if state.srtp_keying_material_event do
        [{:event, {pad, state.srtp_keying_material_event}}]
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

    {{:ok, [caps: {pad, %RTP{}}] ++ events ++ Enum.reverse(buffered_actions || [])},
     %State{state | output_pad_ids: MapSet.put(state.output_pad_ids, ssrc)}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id), _ctx, state) do
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
  def handle_process(Pad.ref(:input, _id) = pad, buffer, _ctx, state) do
    %Membrane.Buffer{
      metadata: %{rtp: %{ssrc: ssrc, payload_type: payload_type, extensions: extensions}}
    } = buffer

    IO.inspect({ssrc, buffer.payload}, label: "a packet_arrival_telemetry payload", limit: :infinity)

    Membrane.TelemetryMetrics.execute(
      [:packet_arrival, :rtp],
      packet_arrival_telemetry_measurements(ssrc, buffer.payload, state) |> IO.inspect(label: "packet_arrival_telemetry_measurements"),
      %{ssrc: ssrc}
    )

    {new_stream_actions, state} =
      maybe_handle_new_stream(pad, ssrc, payload_type, extensions, state)

    {actions, state} = maybe_add_to_linking_buffer(:buffer, buffer, ssrc, state)
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
  def handle_event(_pad, %SRTP.KeyingMaterialEvent{} = event, _ctx, state) do
    {actions, state} =
      Enum.flat_map_reduce(state.input_pads, state, fn {ssrc, _input}, state ->
        maybe_add_to_linking_buffer(:event, event, ssrc, state)
      end)

    {{:ok, actions}, %{state | srtp_keying_material_event: event}}
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

  defp packet_arrival_telemetry_measurements(ssrc, payload, state) do
    %{bytes: byte_size(payload)}
    |> maybe_add_keyframe_indicator(ssrc, payload, state)
    |> maybe_add_frame_indicator(ssrc, payload, state)
  end

  defp maybe_add_keyframe_indicator(measurements, ssrc, payload, state) do
    case state.ssrc_to_keyframe_detector[ssrc] do
      detector when is_function(detector) ->
        # if detector.(payload) |> IO.inspect(label: "maybe_add_keyframe_indicator") do
        if detector.(payload) do
          Map.put(measurements, :keyframe_indicator, 1)
        else
          Map.put(measurements, :keyframe_indicator, 0)
        end

      nil ->
        measurements
    end
  end

  defp maybe_add_frame_indicator(measurements, ssrc, payload, state) do
    case state.ssrc_to_frame_detector[ssrc] do
      detector when is_function(detector) ->
        # if detector.(payload) |> IO.inspect(label: "maybe_add_frame_indicator") do
        if detector.(payload) do
          Map.put(measurements, :frame_indicator, 1)
        else
          Map.put(measurements, :frame_indicator, 0)
        end

      nil ->
        measurements
    end
  end
end
