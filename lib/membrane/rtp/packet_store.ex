defmodule Membrane.RTP.PacketStore do
  @moduledoc """
  Store for entries associated with RTP packets' sequence numbers.
  Can be used to store the packets themselves or just sequence numbers (with no data)

  Entries are stored in `Heap` ordered by packet index.
  """

  use Bunch
  use Bunch.Access
  alias Membrane.RTP
  alias Membrane.RTP.Utils
  alias Membrane.RTP.PacketStore.Entry

  require Bitwise

  @typedoc """
  The monotonic packet index that doesn't wrap at 16-bit boundary

  It is index is defined in RFC 3711 (SRTP) as: `2^16 * rollover count + sequence number`.
  """
  @type packet_index :: non_neg_integer()

  @seq_number_limit Bitwise.bsl(1, 16)

  defstruct flush_index: nil,
            highest_incoming_index: nil,
            heap: Heap.new(&Entry.rtp_comparator/2),
            set: MapSet.new(),
            rollover_count: 0

  @typedoc """
  Type describing BufferStore structure.

  Fields:
  - `rollover_count` - count of all performed rollovers (cycles of sequence number)
  - `heap` - contains entries containing buffers
  - `set` - helper structure for faster read operations; content is the same as in `heap`
  - `flush_index` - index of the last packet that has been emitted (or would have been
  emitted, but never arrived) as a result of a call to one of the `flush` functions
  - `highest_incoming_index` - the highest index in the buffer so far, mapping to the most recently produced
  RTP packet placed in JitterBuffer
  """
  @type t :: %__MODULE__{
          flush_index: JitterBuffer.packet_index() | nil,
          highest_incoming_index: JitterBuffer.packet_index() | nil,
          heap: Heap.t(),
          set: MapSet.t(),
          rollover_count: non_neg_integer()
        }

  @typedoc """
  An atom describing an error that may happen during insertion.
  """
  @type insert_error :: :late_packet

  @typedoc """
  An atom describing an error that may happen when fetching a buffer
  from the Store.
  """
  @type get_buffer_error :: :not_present

  @doc """
  Inserts new entry into the Store.

  Every subsequent buffer must have sequence number Bigger than the previously returned
  one or be part of rollover.
  """
  @spec insert_data(t(), RTP.Header.sequence_number_t(), any()) ::
          {:ok, t()} | {:error, insert_error()}
  def insert_data(%__MODULE__{flush_index: nil} = store, 0, data) do
    store = add_entry(store, Entry.new(data, @seq_number_limit), :next)
    {:ok, %__MODULE__{store | flush_index: @seq_number_limit - 1}}
  end

  def insert_data(%__MODULE__{flush_index: nil} = store, seq_num, data) do
    store = add_entry(store, Entry.new(data, seq_num), :current)
    {:ok, %__MODULE__{store | flush_index: seq_num - 1}}
  end

  def insert_data(
        %__MODULE__{
          flush_index: flush_index,
          highest_incoming_index: highest_incoming_index,
          rollover_count: roc
        } = store,
        seq_num,
        data
      ) do
    highest_seq_num = rem(highest_incoming_index, @seq_number_limit)

    {rollover, index} =
      case Utils.from_which_rollover(highest_seq_num, seq_num, @seq_number_limit) do
        :current -> {:current, seq_num + roc * @seq_number_limit}
        :previous -> {:previous, seq_num + (roc - 1) * @seq_number_limit}
        :next -> {:next, seq_num + (roc + 1) * @seq_number_limit}
      end

    if is_fresh_packet?(flush_index, index) do
      entry = Entry.new(data, index)
      {:ok, add_entry(store, entry, rollover)}
    else
      {:error, :late_packet}
    end
  end

  # TODO: docs
  @doc """
  """
  @spec seq_num_window_size(t()) :: non_neg_integer()
  def seq_num_window_size(%__MODULE__{flush_index: lower, highest_incoming_index: upper})
      when is_integer(lower) and is_integer(upper) do
    upper - lower
  end

  def seq_num_window_size(%__MODULE__{}), do: 0

  def extended_highest_seq_num(%__MODULE__{highest_incoming_index: idx}), do: idx

  @doc """
  Flushes the store to the buffer with the next sequence number.

  If this buffer is present, it will be returned.
  Otherwise it will be treated as late and rejected on attempt to insert into the store.
  """
  @spec flush_one(t) :: {Entry.t() | nil, t}
  def flush_one(store)

  def flush_one(%__MODULE__{flush_index: nil} = store) do
    {nil, store}
  end

  def flush_one(%__MODULE__{flush_index: flush_index, heap: heap, set: set} = store) do
    entry = Heap.root(heap)

    expected_next_index = flush_index + 1

    {result, store} =
      if entry != nil and entry.index == expected_next_index do
        updated_heap = Heap.pop(heap)
        updated_set = MapSet.delete(set, entry.index)

        updated_store = %__MODULE__{store | heap: updated_heap, set: updated_set}

        {entry, updated_store}
      else
        # TODO: instead of nil use expected_next_index to put in Discontinuity metadata
        #       after https://github.com/membraneframework/membrane-core/issues/238 is done.
        {nil, store}
      end

    {result, %__MODULE__{store | flush_index: expected_next_index}}
  end

  @doc """
  Flushes the store until the first gap in sequence numbers of entries
  """
  @spec flush_ordered(t) :: {[Entry.t() | nil], t}
  def flush_ordered(store) do
    flush_while(store, fn %__MODULE__{flush_index: flush_index}, %Entry{index: index} ->
      index == flush_index + 1
    end)
  end

  @doc """
  Flushes the store as long as it contains a buffer with the timestamp older than provided duration
  """
  @spec flush_older_than(t, Membrane.Time.t()) :: {[Entry.t() | nil], t}
  def flush_older_than(store, max_age) do
    max_age_timestamp = Membrane.Time.monotonic_time() - max_age

    flush_while(store, fn _store, %Entry{timestamp: timestamp} ->
      timestamp <= max_age_timestamp
    end)
  end

  @doc """
  Returns all buffers that are stored in the `BufferStore`.
  """
  @spec dump(t()) :: [Entry.t()]
  def dump(%__MODULE__{} = store) do
    {entries, _store} = flush_while(store, fn _store, _entry -> true end)
    entries
  end

  @doc """
  Returns timestamp (time of insertion) of a buffer with lowest index
  """
  @spec first_entry_timestamp(t()) :: Membrane.Time.t() | nil
  def first_entry_timestamp(%__MODULE__{heap: heap}) do
    case Heap.root(heap) do
      %Entry{timestamp: time} -> time
      nil -> nil
    end
  end

  defp is_fresh_packet?(flush_index, index), do: index > flush_index

  @spec flush_while(t, (t, Entry.t() -> boolean), [Entry.t() | nil]) ::
          {[Entry.t() | nil], t}
  defp flush_while(%__MODULE__{heap: heap} = store, fun, acc \\ []) do
    heap
    |> Heap.root()
    |> case do
      nil ->
        {Enum.reverse(acc), store}

      entry ->
        if fun.(store, entry) do
          {entry, store} = flush_one(store)
          flush_while(store, fun, [entry | acc])
        else
          {Enum.reverse(acc), store}
        end
    end
  end

  defp add_entry(%__MODULE__{heap: heap, set: set} = store, %Entry{} = entry, entry_rollover) do
    if set |> MapSet.member?(entry.index) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, entry), set: MapSet.put(set, entry.index)}
      |> update_highest_incoming_index(entry.index)
      |> update_roc(entry_rollover)
    end
  end

  @spec get_entry(t(), (Entry.t() -> boolean())) :: {:ok, Entry.t()} | {:error, :not_found}
  def get_entry(%__MODULE__{heap: heap} = _store, filter_fun) do
    heap
    |> Enum.find(filter_fun)
    |> case do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp update_highest_incoming_index(
         %__MODULE__{highest_incoming_index: last} = store,
         added_index
       )
       when added_index > last or last == nil,
       do: %__MODULE__{store | highest_incoming_index: added_index}

  defp update_highest_incoming_index(
         %__MODULE__{highest_incoming_index: last} = store,
         added_index
       )
       when last >= added_index,
       do: store

  defp update_roc(%{rollover_count: roc} = store, :next),
    do: %__MODULE__{store | rollover_count: roc + 1}

  defp update_roc(store, _entry_rollover), do: store
end

defimpl Enumerable, for: Membrane.RTP.PacketStore do
  alias Membrane.RTP.PacketStore

  def count(%PacketStore{set: set}), do: {:ok, MapSet.size(set)}
  def reduce(%PacketStore{heap: heap}, acc, fun), do: Enum.reduce(heap, acc, fun)
  def member?(%PacketStore{set: set}, element), do: {:ok, MapSet.member?(set, element)}
  def slice(_store), do: raise("Not implemented")
end
