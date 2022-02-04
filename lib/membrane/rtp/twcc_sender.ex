defmodule Membrane.RTP.TWCCSender do
  @moduledoc """
  The module defines an element responsible for tagging outgoing packets with transport-wide sequence numbers.
  """
  use Membrane.Filter

  alias Membrane.RTP
  alias Membrane.RTP.Header

  require Bitwise

  @seq_number_limit Bitwise.bsl(1, 16)

  def_input_pad :input, caps: RTP, availability: :on_request, demand_mode: :auto
  def_output_pad :output, caps: RTP, availability: :on_request, demand_mode: :auto

  @impl true
  def handle_init(_options) do
    {:ok, %{seq_num: 0}}
  end

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, _ctx, state) do
    {{:ok, caps: {Pad.ref(:output, id), caps}}, state}
  end

  @impl true
  def handle_event(Pad.ref(direction, id), event, _ctx, state) do
    opposite_direction = if direction == :input, do: :output, else: :input
    {{:ok, event: {Pad.ref(opposite_direction, id), event}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, id), buffer, _ctx, state) do
    {seq_num, state} = Map.get_and_update!(state, :seq_num, &{&1, rem(&1 + 1, @seq_number_limit)})

    buffer =
      Header.Extension.put(buffer, %Header.Extension{identifier: :twcc, data: <<seq_num::16>>})

    {{:ok, buffer: {Pad.ref(:output, id), buffer}}, state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, id), _ctx, state) do
    {{:ok, end_of_stream: Pad.ref(:output, id)}, state}
  end
end
