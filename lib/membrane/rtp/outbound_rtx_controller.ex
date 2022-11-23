defmodule Membrane.RTP.OutboundRtxController do
  use Membrane.Filter

  alias Membrane.RTP.RetransmissionRequest
  alias Membrane.RTP.JitterBuffer.BufferStore

  require Membrane.Logger

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
  def handle_process(:input, buffer, _ctx, state) when not buffer.metadata.is_padding? do
    state
    |> Map.update!(:store, fn store ->
      case BufferStore.insert_buffer(store, buffer) do
        {:ok, new_store} ->
          maintain_store_size(new_store)

        {:error, :late_packet} ->
          store
      end
    end)
    |> then(&{{:ok, forward: buffer}, &1})
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state), do: {{:ok, forward: buffer}, state}

  @impl true
  def handle_event(
        :input,
        %RetransmissionRequest{sequence_numbers: sequence_numbers},
        _ctx,
        state
      ) do
    buffers_to_retransmit =
      sequence_numbers
      |> Stream.map(fn seq_num -> BufferStore.get_buffer(state.store, seq_num) end)
      |> Stream.filter(fn
        {:ok, buffer} ->
          seq_num = buffer.metadata.rtp.sequence_number

          not Map.has_key?(state.last_rtx_times, seq_num) or
            Map.fetch!(state.last_rtx_times, seq_num) > @min_rtx_interval

        {:error, :not_found} ->
          false
      end)
      |> Enum.map(fn {:ok, buffer} -> buffer end)

    time = System.monotonic_time(:millisecond)

    state =
      Map.update!(state, :last_rtx_times, fn times ->
        updates =
          Map.new(buffers_to_retransmit, fn buffer ->
            {buffer.metadata.rtp.sequence_number, time}
          end)

        Map.merge(times, updates)
      end)

    unless buffers_to_retransmit == [],
      do:
        Membrane.Logger.info(
          "Retransmitting buffers with the following sequence numbers:\n#{inspect(Enum.map(buffers_to_retransmit, & &1.metadata.rtp.sequence_number))}"
        )

    {{:ok, buffer: {:output, buffers_to_retransmit}}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp maintain_store_size(store) do
    if Enum.count(store) > @max_store_size do
      {_entry, store} = BufferStore.flush_one(store)
      store
    else
      store
    end
  end
end
