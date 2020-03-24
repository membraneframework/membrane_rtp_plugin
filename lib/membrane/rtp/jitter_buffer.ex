defmodule Membrane.RTP.JitterBuffer do
  @doc """
  Element that buffers and reorders RTP packets based on sequence_number.
  """
  use Membrane.Filter
  use Bunch
  alias __MODULE__.{BufferStore, Record}
  alias Membrane.Caps.RTP, as: Caps

  use Membrane.Log

  @type packet_index :: non_neg_integer()
  @type sequence_number :: 0..65_535
  @type timestamp :: pos_integer()

  def_output_pad :output,
    caps: Caps

  def_input_pad :input,
    caps: Caps,
    demand_unit: :buffers

  @default_latency 200 |> Membrane.Time.millisecond()

  def_options latency: [
                type: :time,
                default: @default_latency,
                description: """
                Delay introduced by JitterBuffer
                """
              ]

  defmodule State do
    @moduledoc false
    defstruct store: %BufferStore{},
              latency: nil,
              waiting?: true,
              max_latency_timer: nil

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            latency: Membrane.Time.t(),
            waiting?: boolean(),
            max_latency_timer: reference
          }
  end

  @impl true
  def handle_init(%__MODULE__{latency: latency}) do
    {:ok, %State{latency: latency}}
  end

  @impl true
  def handle_start_of_stream(:input, _context, state) do
    Process.send_after(
      self(),
      :initial_latency_passed,
      state.latency |> Membrane.Time.to_milliseconds()
    )

    {:ok, %{state | waiting?: true}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state),
    do: {{:ok, demand: {:input, size}}, state}

  @impl true
  def handle_end_of_stream(:input, _context, %State{store: store} = state) do
    store
    |> BufferStore.dump()
    |> Enum.map(&record_to_action/1)
    ~> {{:ok, &1 ++ [end_of_stream: :output]}, %State{state | store: %BufferStore{}}}
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

    actions = (too_old_records ++ buffers) |> Enum.map(&record_to_action/1)

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
          since_insertion = Membrane.Time.monotonic_time() - buffer_ts
          send_after_time = max(0, latency - since_insertion) |> Membrane.Time.to_milliseconds()
          Process.send_after(self(), :send_buffers, send_after_time)
      end

    %State{state | max_latency_timer: new_timer}
  end

  defp set_timer(%State{max_latency_timer: timer} = state) when timer != nil, do: state

  defp record_to_action(nil), do: {:event, {:output, %Membrane.Event.Discontinuity{}}}
  defp record_to_action(%Record{buffer: buffer}), do: {:buffer, {:output, buffer}}
end
