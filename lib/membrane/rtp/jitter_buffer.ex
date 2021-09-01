defmodule Membrane.RTP.JitterBuffer do
  @moduledoc """
  Element that buffers and reorders RTP packets based on `sequence_number`.
  """
  use Membrane.Filter
  use Membrane.Log
  use Bunch

  alias Membrane.{Buffer, RTP, Time}
  alias __MODULE__.{BufferStore, Record}

  @type packet_index :: non_neg_integer()

  @max_timestamp 0xFFFFFFFF

  def_output_pad :output,
    caps: RTP

  def_input_pad :input,
    caps: RTP,
    demand_unit: :buffers

  @default_latency 200 |> Time.milliseconds()

  def_options clock_rate: [type: :integer, spec: RTP.clock_rate_t()],
              latency: [
                type: :time,
                default: @default_latency,
                description: """
                Delay introduced by JitterBuffer
                """
              ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    defstruct store: %BufferStore{},
              clock_rate: nil,
              latency: nil,
              waiting?: true,
              max_latency_timer: nil,
              timestamp_base: nil,
              previous_timestamp: -1

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            clock_rate: RTP.clock_rate_t(),
            latency: Time.t(),
            waiting?: boolean(),
            max_latency_timer: reference
          }
  end

  @impl true
  def handle_init(%__MODULE__{latency: latency, clock_rate: clock_rate}) do
    if latency == nil do
      raise "Latancy cannot be nil"
    end

    {:ok, %State{latency: latency, clock_rate: clock_rate}}
  end

  @impl true
  def handle_start_of_stream(:input, _context, state) do
    Process.send_after(
      self(),
      :initial_latency_passed,
      state.latency |> Time.to_milliseconds()
    )

    {:ok, %{state | waiting?: true}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state),
    do: {{:ok, demand: {:input, size}}, state}

  @impl true
  def handle_end_of_stream(:input, _context, %State{store: store} = state) do
    {actions, state} =
      store
      |> BufferStore.dump()
      |> Enum.map_reduce(state, &record_to_action/2)

    {{:ok, actions ++ [end_of_stream: :output]}, %State{state | store: %BufferStore{}}}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store, waiting?: true} = state) do
    state =
      case BufferStore.insert_buffer(store, buffer) do
        {:ok, result} ->
          %State{state | store: result}

        {:error, :late_packet} ->
          warn("Late packet has arrived")
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store} = state) do
    case BufferStore.insert_buffer(store, buffer) do
      {:ok, result} ->
        state = %State{state | store: result}
        send_buffers(state)

      {:error, :late_packet} ->
        warn("Late packet has arrived")
        {{:ok, redemand: :output}, state}
    end
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  @impl true
  def handle_other(:initial_latency_passed, _context, state) do
    state = %State{state | waiting?: false}
    send_buffers(state)
  end

  @impl true
  def handle_other(:send_buffers, _context, state) do
    state = %State{state | max_latency_timer: nil}
    send_buffers(state)
  end

  defp send_buffers(%State{store: store} = state) do
    # Shift buffers that stayed in queue longer than latency and any gaps before them
    {too_old_records, store} = BufferStore.shift_older_than(store, state.latency)
    # Additionally, shift buffers as long as there are no gaps
    {buffers, store} = BufferStore.shift_ordered(store)

    {actions, state} = (too_old_records ++ buffers) |> Enum.map_reduce(state, &record_to_action/2)

    state = %{state | store: store} |> set_timer()

    {{:ok, actions ++ [redemand: :output]}, state}
  end

  @spec set_timer(State.t()) :: State.t()
  defp set_timer(%State{max_latency_timer: nil, latency: latency} = state) do
    new_timer =
      case BufferStore.first_record_timestamp(state.store) do
        nil ->
          nil

        buffer_ts ->
          since_insertion = Time.monotonic_time() - buffer_ts
          send_after_time = max(0, latency - since_insertion) |> Time.to_milliseconds()
          Process.send_after(self(), :send_buffers, send_after_time)
      end

    %State{state | max_latency_timer: new_timer}
  end

  defp set_timer(%State{max_latency_timer: timer} = state) when timer != nil, do: state

  defp record_to_action(nil, state) do
    action = {:event, {:output, %Membrane.Event.Discontinuity{}}}
    {action, state}
  end

  defp record_to_action(%Record{buffer: buffer}, state) do
    %{timestamp: rtp_timestamp} = buffer.metadata.rtp
    timestamp_base = state.timestamp_base || rtp_timestamp

    timestamp_base =
      if rtp_timestamp < state.previous_timestamp,
        do: timestamp_base - @max_timestamp - 1,
        else: timestamp_base

    timestamp = Ratio.div((rtp_timestamp - timestamp_base) * Time.second(), state.clock_rate)
    buffer = Bunch.Struct.put_in(buffer, [:metadata, :timestamp], timestamp)
    action = {:buffer, {:output, buffer}}
    state = %{state | timestamp_base: timestamp_base, previous_timestamp: rtp_timestamp}
    {action, state}
  end
end
