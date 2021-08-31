defmodule Membrane.RTP.StatsAccumulator do
  # TODO: support for discarding packets and repairing their sequence numbers

  use Membrane.Filter

  alias Membrane.Time
  alias Membrane.Buffer

  @max_seq_num 0xFFFF
  @max_dropout 3000
  @max_unordered 3000

  @max_s24_val 8_388_607
  @min_s24_val -8_388_608

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any

  def_options clock_rate: [type: :integer, spec: Membrane.RTP.clock_rate_t()]

  defmodule State do
    @type t :: %__MODULE__{
            clock_rate: non_neg_integer(),
            jitter: float(),
            transit: non_neg_integer() | nil,
            received: non_neg_integer(),
            cycles: non_neg_integer(),
            max_seq: non_neg_integer(),
            base_seq: non_neg_integer(),
            received_prior: non_neg_integer(),
            expected_prior: non_neg_integer(),
            lost: non_neg_integer(),
            fraction_lost: float(),
            discarded: non_neg_integer()
          }

    @enforce_keys [:clock_rate]
    defstruct @enforce_keys ++
                [
                  jitter: 0.0,
                  transit: nil,
                  received: 0,
                  cycles: 0,
                  max_seq: nil,
                  base_seq: nil,
                  received_prior: 0,
                  expected_prior: 0,
                  lost: 0,
                  fraction_lost: 0.0,
                  discarded: 0
                ]
  end

  @impl true
  def handle_init(opts) do
    {:ok, %State{clock_rate: opts.clock_rate}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, %State{cycles: cycles, max_seq: max_seq} = state) do
    seq_num = buffer.metadata.rtp.sequence_number
    max_seq = max_seq || seq_num - 1

    delta = rem(seq_num - max_seq + @max_seq_num, @max_seq_num)

    cond do
      # greater sequence number but within dropout to ensure that it is not from previous cycle
      delta < @max_dropout ->
        state =
          state
          |> update_sequence_counters(seq_num, max_seq, cycles)
          |> update_received()
          |> update_jitter(buffer)

        {{:ok, buffer: {:output, buffer}}, state}

      # the packets is either too old or too new
      delta <= @max_seq_num - @max_unordered ->
        {:ok, state}

      # packet is old but within dropout threshold
      true ->
        state =
          state
          |> update_received()
          |> update_jitter(buffer)

        {{:ok, buffer, {:output, buffer}}, update_received(state)}
    end
  end

  @impl true
  def handle_event(:input, %Membrane.RTP.JitterBuffer.StatsRequestEvent{}, _ctx, state) do
    %State{
      received: received,
      received_prior: received_prior,
      expected_prior: expected_prior,
      cycles: cycles,
      max_seq: max_seq,
      jitter: jitter
    } = state

    expected = expected_packets(state)

    lost =
      if expected > received do
        expected - received
      else
        0
      end

    expected_interval = expected - expected_prior
    received_interval = received - received_prior

    lost_interval = expected_interval - received_interval

    fraction_lost =
      if expected_interval == 0 || lost_interval <= 0 do
        0.0
      else
        lost_interval / expected_interval
      end

    IO.inspect(
      "Expected interval #{expected_interval}, Received interval: #{received_interval}, Fraction lost #{fraction_lost}"
    )

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

    stats =
      %Membrane.RTP.JitterBuffer.Stats{
        fraction_lost: fraction_lost,
        total_lost: total_lost,
        highest_seq_num: max_seq + cycles,
        interarrival_jitter: jitter
      }
      |> IO.inspect()

    {{:ok, event: {:input, %Membrane.RTP.JitterBuffer.StatsEvent{stats: stats}}}, state}
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
end
