defmodule Membrane.RTP.BufferFactory do
  @moduledoc false
  alias Membrane.Buffer
  alias Membrane.RTP

  @timestamp_increment 30_000

  @spec timestamp_increment() :: RTP.Header.timestamp_t()
  def timestamp_increment(), do: @timestamp_increment

  @spec sample_buffer(RTP.Header.sequence_number_t()) :: Membrane.Buffer.t()
  def sample_buffer(seq_num) do
    %Buffer{
      payload: <<0, 255>>,
      metadata: %{
        rtp: %{
          timestamp: seq_num * @timestamp_increment,
          sequence_number: seq_num
        }
      }
    }
  end
end
