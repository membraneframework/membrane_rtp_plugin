defmodule Membrane.RTP.OutboundRtxController do
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.RTP.RetransmissionRequestEvent

  def_input_pad :input,
    availability: :always,
    demand_mode: :auto,
    accepted_format: _any

  def_output_pad :output,
    availability: :always,
    demand_mode: :auto,
    accepted_format: _any

  @max_store_size 300
  @min_rtx_interval 10

  @doc false
  @spec max_store_size() :: pos_integer()
  def max_store_size(), do: @max_store_size

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{store: %{}}}

  @impl true
  def handle_process(:input, buffer, _ctx, state) when byte_size(buffer.payload) > 0 do
    idx = sn_to_index(buffer.metadata.rtp.sequence_number)

    state = put_in(state, [:store, idx], {nil, buffer})

    {[forward: buffer], state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state), do: {[forward: buffer], state}

  @impl true
  def handle_event(
        :input,
        %RetransmissionRequestEvent{packet_ids: sequence_numbers},
        _ctx,
        state
      ) do
    Membrane.Logger.debug(
      "Got RTX request of size #{length(sequence_numbers)}: #{inspect(sequence_numbers)}"
    )

    now = System.monotonic_time(:millisecond)

    {buffers, store} =
      Enum.map_reduce(sequence_numbers, state.store, fn seq_num, store ->
        maybe_retransmit(seq_num, now, store)
      end)

    buffers_to_retransmit = Enum.reject(buffers, &is_nil/1)

    unless buffers_to_retransmit == [] do
      Membrane.Logger.debug(
        "Retransmitting #{length(buffers_to_retransmit)} buffer(s): #{inspect(Enum.map(buffers_to_retransmit, & &1.metadata.rtp.sequence_number))}"
      )
    end

    {[buffer: {:output, buffers_to_retransmit}], %{state | store: store}}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp sn_to_index(seq_num), do: rem(seq_num, @max_store_size)

  defp maybe_retransmit(seq_num, now, store) do
    idx = rem(seq_num, @max_store_size)
    {last_rtx_time, buffer} = Map.get(store, idx, {nil, nil})

    if buffer != nil and buffer.metadata.rtp.sequence_number == seq_num and
         time_elapsed?(last_rtx_time, now) do
      store = Map.put(store, idx, {now, buffer})
      {buffer, store}
    else
      {nil, store}
    end
  end

  defp time_elapsed?(nil, _now), do: true
  defp time_elapsed?(last_rtx_time, now), do: now - last_rtx_time >= @min_rtx_interval
end
