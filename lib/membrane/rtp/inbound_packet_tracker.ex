defmodule Membrane.RTP.InboundPacketTracker do
  @moduledoc """
  Module responsible for tracking statistics of incoming RTP packets for a single stream.

  Tracker is capable of repairing packets' sequence numbers provided that it has information about how many packets has
  been previously discarded. To updated number of discarded packets one should send an event `Membrane.RTP.PacketsDiscarded.t/0` that will accumulate
  the total number of discarded packets and will subtract that number from the packet's sequence number.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, Time}
  alias Membrane.RTCP.ReceiverReport
  alias Membrane.RTP.{PacketStore, RetransmissionRequest}

  require Bitwise
  require Membrane.Logger

  @max_dropout 3000

  # Number of packets we wait before we decide packet was not reordered, but lost
  @reorder_window 16

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
            sequence_num_store: PacketStore.t(),
            received_prior: non_neg_integer(),
            expected_prior: non_neg_integer()
          }

    @enforce_keys [:clock_rate, :repair_sequence_numbers?]
    defstruct @enforce_keys ++
                [
                  sequence_num_store: %PacketStore{},
                  first_sequence_number: nil,
                  jitter: 0.0,
                  transit: nil,
                  received: 0,
                  discarded: 0,
                  received_prior: 0,
                  expected_prior: 0
                ]
  end

  @impl true
  def handle_init(opts) do
    {:ok,
     %State{clock_rate: opts.clock_rate, repair_sequence_numbers?: opts.repair_sequence_numbers?}}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, %State{first_sequence_number: nil} = state) do
    seq_num = buffer.metadata.rtp.sequence_number
    process_buffer(buffer, seq_num, %State{state | first_sequence_number: seq_num})
  end

  def handle_process(:input, buffer, _ctx, %State{} = state) do
    seq_num = buffer.metadata.rtp.sequence_number
    process_buffer(buffer, seq_num, state)
  end

  # credo:disable-for-lines:65
  defp process_buffer(buffer, seq_num, %State{} = state) do
    state = state |> update_received()

    {action, state} =
      state.sequence_num_store
      |> PacketStore.insert_data(seq_num, nil)
      |> case do
        {:ok, store} ->
          {:pass, %State{state | sequence_num_store: store}}

        {:error, :late_packet} ->
          # Determine how late the packet is
          max_seq_num =
            state.sequence_num_store |> PacketStore.extended_highest_seq_num() |> mod_uint16()

          diff = mod_uint16(max_seq_num - seq_num)

          if diff > @max_dropout do
            {:drop, state}
          else
            Membrane.Logger.info("Seems like a succesful retransmission of #{seq_num}")
            {:pass, state}
          end
      end

    state =
      case action do
        :drop -> state
        :pass -> update_jitter(state, buffer)
      end

    actions =
      case action do
        :drop -> []
        :pass -> [buffer: {:output, repair_sequence_number(buffer, state)}]
      end

    {missing_seq_num, state} =
      if PacketStore.seq_num_window_size(state.sequence_num_store) > @reorder_window do
        {result, store} = PacketStore.flush_one(state.sequence_num_store)
        state = %State{state | sequence_num_store: store}
        # Check if we need to send NACK
        case result do
          nil -> {store.flush_index, state}
          _entry -> {nil, state}
        end
      else
        {nil, state}
      end

    actions =
      case missing_seq_num do
        nil ->
          actions

        _seq_num ->
          [
            {:event, {:input, %RetransmissionRequest{sequence_numbers: [missing_seq_num]}}}
            | actions
          ]
      end

    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(:input, %ReceiverReport.StatsRequestEvent{}, _ctx, state) do
    %State{
      received: received,
      received_prior: received_prior,
      expected_prior: expected_prior,
      sequence_num_store: store,
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
        received_prior: received
    }

    stats = %ReceiverReport.Stats{
      fraction_lost: fraction_lost,
      total_lost: total_lost,
      highest_seq_num: PacketStore.extended_highest_seq_num(store),
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
    {:ok, %State{state | discarded: mod_uint16(discarded + packets_discarded)}}
  end

  @impl true
  def handle_event(direction, event, ctx, state), do: super(direction, event, ctx, state)

  defp update_received(%State{received: received} = state) do
    %State{state | received: received + 1}
  end

  defp expected_packets(%State{sequence_num_store: store, first_sequence_number: base_seq}) do
    PacketStore.extended_highest_seq_num(store) - base_seq + 1
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
        mod_uint16(seq_num - discarded)
      )

    %Buffer{buffer | metadata: metadata}
  end

  defp mod_uint16(input) when is_integer(input) do
    # trim input to 16 bit and treat as unsigned
    <<result::16>> = <<input::16-unsigned>>
    result
  end
end
