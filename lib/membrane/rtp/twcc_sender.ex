defmodule Membrane.RTP.TWCCSender do
  @moduledoc """
  The module defines an element responsible for tagging outgoing packets with transport-wide sequence numbers.
  """
  use Membrane.Filter

  alias Membrane.{RTP, Time}
  alias Membrane.RTP.Header
  alias Membrane.RTCP.TransportFeedbackPacket.TWCC
  alias __MODULE__.CongestionControl

  require Bitwise
  require Membrane.Logger

  @seq_number_limit Bitwise.bsl(1, 16)

  def_input_pad :input, caps: RTP, availability: :on_request, demand_mode: :auto
  def_output_pad :output, caps: RTP, availability: :on_request, demand_mode: :auto

  @impl true
  def handle_init(_options) do
    {:ok,
     %{
       seq_num: 0,
       last_ts: nil,
       seq_to_delta: %{},
       seq_to_size: %{},
       cc: %CongestionControl{},
       bandwidth_report_interval: Time.seconds(5)
     }}
  end

  @impl true
  def handle_pad_added(_pad, _ctx, state), do: {:ok, %{state | cc: %CongestionControl{}}}

  @impl true
  def handle_pad_removed(_pad, _ctx, state), do: {:ok, %{state | cc: %CongestionControl{}}}

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, _ctx, state) do
    {{:ok, caps: {Pad.ref(:output, id), caps}}, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:bandwidth_report_timer, state.bandwidth_report_interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: :bandwidth_report_timer}, state}
  end

  @impl true
  def handle_tick(:bandwidth_report_timer, _ctx, %{cc: cc} = state) do
    {{:ok, notify: {:bandwidth_estimation, min(cc.a_hat, cc.as_hat)}}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, id), size, :buffers, _ctx, state) do
    {{:ok, demand: {Pad.ref(:input, id), size}}, state}
  end

  @impl true
  def handle_event(Pad.ref(direction, id), event, _ctx, state) do
    opposite_direction = if direction == :input, do: :output, else: :input
    {{:ok, event: {Pad.ref(opposite_direction, id), event}}, state}
  end

  @impl true
  def handle_other({:twcc_feedback, feedback}, _ctx, state) do
    %TWCC{
      base_seq_num: base_seq_num,
      feedback_packet_count: feedback_packet_count,
      packet_status_count: packet_count,
      receive_deltas: receive_deltas,
      reference_time: reference_time
    } = feedback

    max_seq_num = base_seq_num + packet_count - 1

    sequence_numbers = Enum.map(base_seq_num..max_seq_num, &rem(&1, @seq_number_limit))

    send_deltas = Enum.map(sequence_numbers, &Map.fetch!(state.seq_to_delta, &1))
    packet_sizes = Enum.map(sequence_numbers, &Map.fetch!(state.seq_to_size, &1))

    cc =
      CongestionControl.update(
        state.cc,
        reference_time,
        receive_deltas,
        send_deltas,
        packet_sizes
      )

    {:ok, %{state | cc: cc}}
  end

  @impl true
  def handle_process(Pad.ref(:input, id), buffer, _ctx, state) do
    {seq_num, state} = Map.get_and_update!(state, :seq_num, &{&1, rem(&1 + 1, @seq_number_limit)})

    buffer =
      Header.Extension.put(buffer, %Header.Extension{identifier: :twcc, data: <<seq_num::16>>})

    current_ts = Time.monotonic_time()
    send_delta = current_ts - (state.last_ts || current_ts)

    state =
      state
      |> put_in([:seq_to_delta, seq_num], send_delta)
      |> put_in([:seq_to_size, seq_num], bit_size(buffer.payload))

    {{:ok, buffer: {Pad.ref(:output, id), buffer}}, %{state | last_ts: current_ts}}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, id), _ctx, state) do
    {{:ok, end_of_stream: Pad.ref(:output, id)}, state}
  end
end
