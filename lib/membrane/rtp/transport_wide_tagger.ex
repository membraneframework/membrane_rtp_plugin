defmodule Membrane.RTP.TransportWideTagger do
  @moduledoc """
  The module defines a simple element responsible for tagging transport-wide sequence number of outgoing packets.
  """
  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request
  def_output_pad :output, caps: :any, availability: :on_request

  @impl true
  def handle_init(_opts) do
    {:ok, %{seq_num: 1}}
  end

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, _ctx, state) do
    {{:ok, caps: {Pad.ref(:output, id), caps}}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, id), size, :buffers, _ctx, state) do
    {{:ok, demand: {Pad.ref(:input, id), size}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, id), event, _ctx, state) do
    {{:ok, event: {Pad.ref(:output, id), event}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:output, id), event, _ctx, state) do
    {{:ok, event: {Pad.ref(:input, id), event}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, id), buffer, _ctx, %{seq_num: seq_num} = state) do
    buffer = Map.update!(buffer, :metadata, &Map.put(&1, :transport_seq_num, seq_num))
    {{:ok, buffer: {Pad.ref(:output, id), buffer}}, %{state | seq_num: seq_num + 1}}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, id), _ctx, state) do
    {{:ok, end_of_stream: Pad.ref(:output, id)}, state}
  end
end
