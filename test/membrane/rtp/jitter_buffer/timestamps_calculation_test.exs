defmodule Membrane.RTP.JitterBuffer.TimestampsCalculationTest do
  use ExUnit.Case, async: true
  use Bunch

  alias Membrane.RTP.JitterBuffer
  alias Membrane.RTP.BufferFactory

  @max_rtp_timestamp 0xFFFFFFFF

  defp action_buffers(actions) do
    actions
    |> Enum.filter(&match?({:buffer, _}, &1))
    |> Enum.map(fn {:buffer, {:output, buffer}} -> buffer end)
  end

  defp buffers_timestamps(buffers) do
    Enum.map(buffers, & &1.metadata.timestamp)
  end

  defp process_and_receive_buffer_timestamps(buffers, state) do
    state =
      Enum.reduce(buffers, state, fn buffer, state ->
        {:ok, state} = JitterBuffer.handle_process(:input, buffer, %{}, state)
        state
      end)

    {{:ok, actions}, state} = JitterBuffer.handle_other(:send_buffers, %{}, state)

    actions
    |> action_buffers()
    |> buffers_timestamps()
  end

  defp update_buffer_timestamp(buffer, timestamp) do
    %{buffer | metadata: put_in(buffer.metadata, [:rtp, :timestamp], timestamp)}
  end

  defp overflowed_timestamp() do
    BufferFactory.timestamp_increment()
  end

  # the higher multiplier the closer timestamp will be to overflow
  defp almost_overflowed_timestamp(multiplier) when multiplier in 1..10 do
    @max_rtp_timestamp - (10 - multiplier - 1) * div(BufferFactory.timestamp_increment(), 10)
  end

  describe "JitterBuffer correctly calculates timestamps for buffers that" do
    setup do
      {:ok, state} =
        JitterBuffer.handle_init(%JitterBuffer{clock_rate: BufferFactory.clock_rate()})

      seq_num = BufferFactory.base_seq_number()
      buffer1 = BufferFactory.sample_buffer(seq_num + 1)
      buffer2 = BufferFactory.sample_buffer(seq_num + 2)

      [state: state, buffer1: buffer1, buffer2: buffer2]
    end

    test "have monotonic timestamps within proper range", ctx do
      %{buffer1: buffer1, buffer2: buffer2} = ctx

      assert buffer1.metadata.rtp.timestamp < buffer2.metadata.rtp.timestamp

      [timestamp1, timestamp2] =
        [buffer1, buffer2]
        |> process_and_receive_buffer_timestamps(ctx.state)

      assert timestamp1 < timestamp2
    end

    test "have non-monotonic timestamps within proper range", ctx do
      %{buffer1: buffer1, buffer2: buffer2} = ctx

      # switch buffers rtp timestamps so that buffer1 has smaller timestamp than buffer 2
      {buffer1, buffer2} = {
        update_buffer_timestamp(buffer1, buffer2.metadata.rtp.timestamp),
        update_buffer_timestamp(buffer2, buffer1.metadata.rtp.timestamp)
      }

      assert buffer1.metadata.rtp.timestamp > buffer2.metadata.rtp.timestamp

      [timestamp1, timestamp2] =
        [buffer1, buffer2]
        |> process_and_receive_buffer_timestamps(ctx.state)

      assert timestamp1 > timestamp2
    end

    test "have monotonic timestamps that are about to overflow", ctx do
      %{buffer1: buffer1, buffer2: buffer2} = ctx

      # both buffers are really close to overflow
      buffer1 = update_buffer_timestamp(buffer1, almost_overflowed_timestamp(1))
      buffer2 = update_buffer_timestamp(buffer2, almost_overflowed_timestamp(2))

      assert buffer1.metadata.rtp.timestamp < buffer2.metadata.rtp.timestamp

      [timestamp1, timestamp2] =
        [buffer1, buffer2]
        |> process_and_receive_buffer_timestamps(ctx.state)

      assert timestamp1 < timestamp2

      # buffer2 has already overflowed
      buffer1 = update_buffer_timestamp(buffer1, almost_overflowed_timestamp(1))
      buffer2 = update_buffer_timestamp(buffer2, overflowed_timestamp())

      assert buffer1.metadata.rtp.timestamp > buffer2.metadata.rtp.timestamp

      [timestamp1, timestamp2] =
        [buffer1, buffer2]
        |> process_and_receive_buffer_timestamps(ctx.state)

      assert timestamp1 < timestamp2
    end

    test "have non-monotonic timestamps that are about to overflow", ctx do
      %{buffer1: buffer1, buffer2: buffer2} = ctx

      # buffer1 overflowed while buffer2 has not,  buffer2's calculated timestamp should be lower than buffer1's
      buffer1 = update_buffer_timestamp(buffer1, overflowed_timestamp())
      buffer2 = update_buffer_timestamp(buffer2, almost_overflowed_timestamp(1))

      assert buffer1.metadata.rtp.timestamp < buffer2.metadata.rtp.timestamp

      [timestamp1, timestamp2] =
        [buffer1, buffer2]
        |> process_and_receive_buffer_timestamps(ctx.state)

      # buffer2's timestamp must be smaller than buffer1's
      assert timestamp2 < timestamp1
    end
  end
end
