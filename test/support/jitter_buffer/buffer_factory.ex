defmodule Membrane.RTP.JitterBufferTest.BufferFactory do
  @moduledoc false
  alias Membrane.Buffer
  alias Membrane.RTP.JitterBuffer

  @timestamp_increment 30_000

  @spec timestamp_increment() :: JitterBuffer.timestamp()
  def timestamp_increment(), do: @timestamp_increment

  @spec sample_buffer(JitterBuffer.sequence_number()) :: Membrane.Buffer.t()
  def sample_buffer(seq_num), do: sample_buffer(seq_num, seq_num)

  @spec sample_buffer(JitterBuffer.sequence_number(), pos_integer()) :: Membrane.Buffer.t()
  def sample_buffer(seq_num, timestamp) do
    %Buffer{
      payload: <<0, 255>>,
      metadata: %{
        rtp: %{
          timestamp: timestamp * @timestamp_increment,
          sequence_number: seq_num
        }
      }
    }
  end
end
