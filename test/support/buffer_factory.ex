defmodule Membrane.RTP.BufferFactory do
  @moduledoc false
  alias Membrane.Buffer
  alias Membrane.RTP

  @timestamp_increment 30_000
  @clock_rate 10_000
  @base_seq_number 50

  @spec timestamp_increment() :: RTP.Header.timestamp_t()
  def timestamp_increment(), do: @timestamp_increment

  @spec clock_rate() :: RTP.clock_rate_t()
  def clock_rate(), do: @clock_rate

  @spec base_seq_number() :: RTP.Header.sequence_number_t()
  def base_seq_number(), do: @base_seq_number

  @spec sample_buffer(RTP.Header.sequence_number_t()) :: Membrane.Buffer.t()
  def sample_buffer(seq_num) do
    seq_num_offset = seq_num - @base_seq_number

    %Buffer{
      payload: <<0, 255>>,
      pts: div(seq_num_offset * @timestamp_increment * Membrane.Time.second(), @clock_rate),
      metadata: %{
        rtp: %{
          timestamp: seq_num_offset * @timestamp_increment,
          sequence_number: seq_num
        }
      }
    }
  end
end
