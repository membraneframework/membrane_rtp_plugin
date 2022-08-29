defmodule Membrane.RTP.OutboundRtxController do
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.RTCPEvent
  alias Membrane.RTCP.TransportFeedbackPacket.NACK
  alias Membrane.RTP.JitterBuffer.BufferStore

  def_input_pad :input,
    availability: :always,
    demand_mode: :auto,
    caps: :any

  def_output_pad :output,
    availability: :always,
    demand_mode: :auto,
    caps: :any

  @max_store_size 300
  @min_rtx_interval 10

  @impl true
  def handle_init(_opts), do: {:ok, %{store: BufferStore.new(), last_rtx_times: %{}}}

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    state
    |> Map.update!(:store, fn store ->
      case BufferStore.insert_buffer(store, buffer) do
        {:ok, new_store} ->
          if Enum.count(new_store) > @max_store_size do
            {_entry, new_store} = BufferStore.flush_one(new_store)
            new_store
          else
            new_store
          end

        {:error, :late_packet} ->
          Membrane.Logger.warn("LATE PACKET")
          store
      end
    end)
    |> then(&{{:ok, forward: buffer}, &1})
  end

  @impl true
  def handle_event(:input, %RTCPEvent{rtcp: %{payload: %NACK{} = nack}}, _ctx, state) do
    packets_to_retransmit =
      nack.lost_packet_ids
      |> Enum.map(fn seq_num -> BufferStore.get_buffer(state.store, seq_num) end)
      |> Enum.filter(&match?({:ok, _buffer}, &1))
      |> Enum.map(fn {:ok, buffer} -> buffer end)
      |> IO.inspect(label: :dupa1)
      |> Enum.filter(fn buffer ->
        seq_num = buffer.metadata.rtp.sequence_number

        not Map.has_key?(state.last_rtx_times, seq_num) or
          Map.fetch!(state.last_rtx_times, seq_num) > @min_rtx_interval
      end)

    time = System.monotonic_time(:millisecond)

    times =
      Map.new(packets_to_retransmit, fn packet -> {packet.metadata.rtp.sequence_number, time} end)

    state = Map.update!(state, :last_rtx_times, &Map.merge(&1, times))

    unless packets_to_retransmit == [],
      do:
        Membrane.Logger.info(
          "Retransmitting packets with the following sequence numbers:\n#{inspect(Enum.map(packets_to_retransmit, & &1.metadata.rtp.sequence_number))}"
        )

    {{:ok, buffer: {:output, packets_to_retransmit}}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)
end
