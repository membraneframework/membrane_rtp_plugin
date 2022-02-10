defmodule Membrane.RTP.TWCCSender do
  @moduledoc """
  The module defines an element responsible for tagging outgoing packets with transport-wide sequence numbers and
  estimating available bandwidth.
  """
  use Membrane.Filter

  alias Membrane.{RTP, Time}
  alias Membrane.RTP.Header
  alias Membrane.RTCP.TransportFeedbackPacket.TWCC
  alias __MODULE__.CongestionControl

  require Bitwise

  @seq_number_limit Bitwise.bsl(1, 16)

  def_input_pad :input, caps: RTP, availability: :on_request, demand_mode: :auto
  def_output_pad :output, caps: RTP, availability: :on_request, demand_mode: :auto

  @impl true
  def handle_init(_options) do
    {:ok,
     %{
       seq_num: 0,
       seq_to_timestamp: %{},
       seq_to_size: %{},
       cc: %CongestionControl{},
       bandwidth_report_interval: Time.seconds(5),
       buffered_actions: %{}
     }}
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    {queued_actions, other_actions} = Map.pop(state.buffered_actions, pad, [])

    {{:ok, Enum.to_list(queued_actions)},
     %{state | cc: %CongestionControl{}, buffered_actions: other_actions}}
  end

  @impl true
  def handle_pad_removed(_pad, _ctx, state), do: {:ok, %{state | cc: %CongestionControl{}}}

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, ctx, state) do
    out_pad = Pad.ref(:output, id)
    [caps: {out_pad, caps}] |> send_when_pad_connected(out_pad, ctx, state)
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
  def handle_event(Pad.ref(direction, id), event, ctx, state) do
    opposite_direction = if direction == :input, do: :output, else: :input
    out_pad = Pad.ref(opposite_direction, id)
    [event: {out_pad, event}] |> send_when_pad_connected(out_pad, ctx, state)
  end

  @impl true
  def handle_other({:twcc_feedback, feedback}, _ctx, state) do
    %TWCC{
      # TODO: consider what to do when we lose some feedback
      feedback_packet_count: _feedback_packet_count,
      reference_time: reference_time,
      base_seq_num: base_seq_num,
      packet_status_count: packet_count,
      receive_deltas: receive_deltas
    } = feedback

    max_seq_num = base_seq_num + packet_count - 1

    rtt =
      Time.monotonic_time() -
        Map.fetch!(state.seq_to_timestamp, rem(max_seq_num, @seq_number_limit))

    sequence_numbers = Enum.map(base_seq_num..max_seq_num, &rem(&1, @seq_number_limit))

    send_timestamps = Enum.map(sequence_numbers, &Map.fetch!(state.seq_to_timestamp, &1))

    timestamp_before_base = Map.get(state.seq_to_timestamp, base_seq_num - 1, hd(send_timestamps))

    send_deltas =
      sequence_numbers
      |> Enum.reduce({[], timestamp_before_base}, fn seq_num, {deltas, previous_timestamp} ->
        timestamp = Map.fetch!(state.seq_to_timestamp, seq_num)
        {[timestamp - previous_timestamp | deltas], timestamp}
      end)
      |> elem(0)
      |> Enum.reverse()

    packet_sizes = Enum.map(sequence_numbers, &Map.fetch!(state.seq_to_size, &1))

    cc =
      CongestionControl.update(
        state.cc,
        reference_time,
        receive_deltas,
        send_deltas,
        packet_sizes,
        rtt
      )

    {:ok, %{state | cc: cc}}
  end

  @impl true
  def handle_process(Pad.ref(:input, id), buffer, ctx, state) do
    {seq_num, state} = Map.get_and_update!(state, :seq_num, &{&1, rem(&1 + 1, @seq_number_limit)})

    buffer =
      Header.Extension.put(buffer, %Header.Extension{identifier: :twcc, data: <<seq_num::16>>})

    state =
      state
      |> put_in([:seq_to_timestamp, seq_num], Time.monotonic_time())
      |> put_in([:seq_to_size, seq_num], bit_size(buffer.payload))

    out_pad = Pad.ref(:output, id)
    [buffer: {out_pad, buffer}] |> send_when_pad_connected(out_pad, ctx, state)
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, id), ctx, state) do
    out_pad = Pad.ref(:output, id)
    [end_of_stream: out_pad] |> send_when_pad_connected(out_pad, ctx, state)
  end

  defp send_when_pad_connected(actions, pad, ctx, state) do
    if Map.has_key?(ctx.pads, pad) do
      {{:ok, actions}, state}
    else
      new_actions = Qex.new(actions)

      {:ok,
       %{
         state
         | buffered_actions:
             Map.update(state.buffered_actions, pad, new_actions, &Qex.join(&1, new_actions))
       }}
    end
  end
end
