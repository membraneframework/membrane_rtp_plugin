defmodule Membrane.RTP.OldInboundPacketTracker do
  @moduledoc """
  Module responsible for tracking statistics of incoming RTP packets for a single stream.

  Tracker is capable of repairing packets' sequence numbers provided that it has information about how many packets has
  been previously discarded. To updated number of discarded packets one should send an event `Membrane.RTP.PacketsDiscarded.t/0` that will accumulate
  the total number of discarded packets and will subtract that number from the packet's sequence number.
  """
  use Membrane.Filter

  require Bitwise
  alias Membrane.RTCP.ReceiverReport
  alias Membrane.{Buffer, RTP, Time}

  @max_dropout 3000
  @max_unordered 3000

  @max_seq_num Bitwise.bsl(1, 16) - 1
  @max_s24_val Bitwise.bsl(1, 23) - 1
  @min_s24_val -Bitwise.bsl(1, 23)

  def_input_pad :input, caps: :any, demand_mode: :auto
  def_output_pad :output, caps: :any, demand_mode: :auto

  def_options clock_rate: [
                type: :integer,
                spec: Membrane.RTP.clock_rate_t()
              ],
              repair_sequence_numbers?: [
                spec: boolean(),
                default: true,
                description: "Defines if tracker should try to repair packet's sequence number"
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            clock_rate: non_neg_integer(),
            repair_sequence_numbers?: boolean(),
            jitter: float(),
            transit: non_neg_integer() | nil,
            received: non_neg_integer(),
            discarded: non_neg_integer(),
            cycles: non_neg_integer(),
            base_seq: non_neg_integer(),
            max_seq: non_neg_integer(),
            received_prior: non_neg_integer(),
            expected_prior: non_neg_integer(),
            lost: non_neg_integer(),
            fraction_lost: float()
          }

    @enforce_keys [:clock_rate, :repair_sequence_numbers?]
    defstruct @enforce_keys ++
                [
                  jitter: 0.0,
                  transit: nil,
                  received: 0,
                  discarded: 0,
                  cycles: 0,
                  base_seq: nil,
                  max_seq: nil,
                  received_prior: 0,
                  expected_prior: 0,
                  lost: 0,
                  fraction_lost: 0.0
                ]
  end

  @impl true
  def handle_init(opts) do
    {:ok,
     %State{clock_rate: opts.clock_rate, repair_sequence_numbers?: opts.repair_sequence_numbers?}}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, %State{cycles: cycles, max_seq: max_seq} = state) do
    seq_num = buffer.metadata.rtp.sequence_number
    max_seq = max_seq || seq_num - 1

    delta = rem(seq_num - max_seq + @max_seq_num + 1, @max_seq_num + 1)

    cond do
      # greater sequence number but within dropout to ensure that it is not from previous cycle
      delta < @max_dropout ->
        state =
          state
          |> update_sequence_counters(seq_num, max_seq, cycles)
          |> update_received()
          |> update_jitter(buffer)

        {{:ok, buffer: {:output, repair_sequence_number(buffer, state)}}, state}

      # the packets is either too old or too new
      delta <= @max_seq_num - @max_unordered ->
        {:ok, update_received(state)}

      # packet is old but within dropout threshold
      true ->
        state =
          state
          |> update_received()
          |> update_jitter(buffer)

        {{:ok, buffer: {:output, repair_sequence_number(buffer, state)}}, update_received(state)}
    end
  end

  @impl true
  def handle_event(:input, %ReceiverReport.StatsRequestEvent{}, _ctx, state) do
    %State{
      received: received,
      received_prior: received_prior,
      expected_prior: expected_prior,
      cycles: cycles,
      max_seq: max_seq,
      jitter: jitter
    } = state

    expected = expected_packets(state)

    lost = max(expected - received, 0)

    expected_interval = expected - expected_prior
    received_interval = received - received_prior

    lost_interval = expected_interval - received_interval

    fraction_lost =
      if expected_interval == 0 || lost_interval <= 0 do
        0.0
      else
        lost_interval / expected_interval
      end

    total_lost =
      cond do
        lost > @max_s24_val -> @max_s24_val
        lost < @min_s24_val -> @min_s24_val
        true -> lost
      end

    state = %State{
      state
      | expected_prior: expected,
        received_prior: received,
        lost: total_lost,
        fraction_lost: fraction_lost
    }

    stats = %ReceiverReport.Stats{
      fraction_lost: fraction_lost,
      total_lost: total_lost,
      highest_seq_num: max_seq + cycles,
      interarrival_jitter: jitter
    }

    {{:ok, event: {:input, %ReceiverReport.StatsEvent{stats: stats}}}, state}
  end

  @impl true
  def handle_event(
        :input,
        %RTP.PacketsDiscardedEvent{discarded: packets_discarded},
        _ctx,
        %State{discarded: discarded} = state
      ) do
    {:ok, %State{state | discarded: discarded + packets_discarded}}
  end

  @impl true
  def handle_event(direction, event, ctx, state), do: super(direction, event, ctx, state)

  defp update_sequence_counters(state, seq_num, max_seq, cycles) do
    {max_seq_num, cycles} =
      if seq_num < max_seq do
        {seq_num, cycles + @max_seq_num}
      else
        {seq_num, cycles}
      end

    %State{state | max_seq: max_seq_num, cycles: cycles, base_seq: state.base_seq || seq_num}
  end

  defp update_received(%State{received: received} = state) do
    %State{state | received: received + 1}
  end

  defp expected_packets(%State{cycles: cycles, max_seq: max_seq, base_seq: base_seq}) do
    cycles + max_seq - base_seq + 1
  end

  defp update_jitter(state, %Buffer{metadata: metadata}) do
    %State{clock_rate: clock_rate, jitter: last_jitter, transit: last_transit} = state

    # Algorithm from https://tools.ietf.org/html/rfc3550#appendix-A.8
    arrival_ts = Map.get(metadata, :arrival_ts, Time.vm_time())
    buffer_ts = metadata.rtp.timestamp
    arrival = arrival_ts |> Time.as_seconds() |> Ratio.mult(clock_rate) |> Ratio.trunc()
    transit = arrival - buffer_ts

    {jitter, transit} =
      if last_transit == nil do
        {last_jitter, transit}
      else
        d = abs(transit - last_transit)
        new_jitter = last_jitter + 1 / 16 * (d - last_jitter)

        {new_jitter, transit}
      end

    %State{state | jitter: jitter, transit: transit}
  end

  defp repair_sequence_number(%Buffer{} = buffer, %State{
         discarded: discarded,
         repair_sequence_numbers?: repair?
       })
       when not repair? or discarded == 0 do
    buffer
  end

  # repairs sequence number if there have been any packets discarded by any of previous elements
  defp repair_sequence_number(
         %Buffer{metadata: %{rtp: %{sequence_number: seq_num}} = metadata} = buffer,
         %State{discarded: discarded}
       ) do
    metadata =
      put_in(
        metadata,
        [:rtp, :sequence_number],
        rem(seq_num - discarded + @max_seq_num + 1, @max_seq_num + 1)
      )

    %Buffer{buffer | metadata: metadata}
  end
end
