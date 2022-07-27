defmodule Membrane.RTP.JitterBuffer.BufferStore do
  @moduledoc false

  # Store for RTP packets. Packets are stored in `Heap` ordered by packet index. Packet index is
  # defined in RFC 3711 (SRTP) as: 2^16 * rollover count + sequence number.

  use Bunch
  use Bunch.Access

  require Bitwise

  alias Membrane.Buffer
  alias Membrane.RTP.PacketStore

  @type t :: PacketStore.t()

  @doc """
  Initialize a new BufferStore
  """
  @spec new() :: t()
  def new(), do: %PacketStore{}

  @doc """
  Inserts buffer into the Store.

  Every subsequent buffer must have sequence number Bigger than the previously returned
  one or be part of rollover.
  """
  @spec insert_buffer(t(), Buffer.t()) :: {:ok, t()} | {:error, PacketStore.insert_error()}
  def insert_buffer(store, %Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} = buffer) do
    PacketStore.insert_data(store, seq_num, buffer)
  end

  defdelegate dump(store), to: PacketStore
  defdelegate flush_one(store), to: PacketStore
  defdelegate flush_older_than(store, timestamp), to: PacketStore
  defdelegate flush_ordered(store), to: PacketStore
  defdelegate first_timestamp(store), to: PacketStore, as: :first_entry_timestamp
end
