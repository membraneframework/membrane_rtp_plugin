defmodule Membrane.RTP.PacketStore.Entry do
  @moduledoc false

  # Describes a structure that is stored in the BufferStore.

  alias Membrane.RTP.PacketStore

  @enforce_keys [:index, :timestamp]
  defstruct @enforce_keys ++ [data: nil]

  @type t() :: t(any())
  @type t(data) :: %__MODULE__{
          index: PacketStore.packet_index(),
          timestamp: Membrane.Time.t(),
          data: data
        }

  @spec new(PacketStore.packet_index()) :: t(nil)
  def new(index) do
    %__MODULE__{
      index: index,
      timestamp: Membrane.Time.monotonic_time()
    }
  end

  @spec new(data, PacketStore.packet_index()) :: t(data) when data: any()
  def new(data, index) do
    %__MODULE__{
      index: index,
      timestamp: Membrane.Time.monotonic_time(),
      data: data
    }
  end

  @doc """
  Compares two records.

  Returns true if the first record is older than the second one.
  """
  # Designed to use with Heap: https://gitlab.com/jimsy/heap/blob/master/lib/heap.ex#L71
  @spec rtp_comparator(t(), t()) :: boolean()
  def rtp_comparator(%__MODULE__{index: l_index}, %__MODULE__{index: r_index}),
    do: l_index < r_index
end
