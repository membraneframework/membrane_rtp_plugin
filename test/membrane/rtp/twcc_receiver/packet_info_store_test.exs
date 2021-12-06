defmodule Membrane.RTP.TWCCReceiver.PacketInfoStoreTest do
  use ExUnit.Case, async: true
  use Bunch

  alias Membrane.RTP.TWCCReceiver.PacketInfoStore

  @max_seq_number 65_535

  setup_all do
    [store: %PacketInfoStore{}]
  end

  describe "When storing packet info, PacketInfoStore" do
    test "updates info about emptiness", %{store: store} do
      assert PacketInfoStore.empty?(store)

      store = PacketInfoStore.insert_packet_info(store, 10)

      refute PacketInfoStore.empty?(store)
    end

    test "stores all sequence numbers", %{store: store} do
      expected_sequence_numbers = MapSet.new(1..10)

      store =
        expected_sequence_numbers
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      sequence_numbers = get_sequence_numbers(store)

      assert MapSet.equal?(sequence_numbers, expected_sequence_numbers)
      assert store.base_seq_num == 1
      assert store.max_seq_num == 10
    end

    test "handles non-received packets", %{store: store} do
      expected_sequence_numbers = MapSet.new(1..11//2)

      store =
        expected_sequence_numbers
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      sequence_numbers = get_sequence_numbers(store)

      assert MapSet.equal?(sequence_numbers, expected_sequence_numbers)
      assert store.base_seq_num == 1
      assert store.max_seq_num == 11
    end

    test "uses non-decreasing timestamps for subsequently added packets", %{store: store} do
      store =
        1..10
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      1..10//2
      |> Enum.zip(2..10//2)
      |> Enum.each(fn {l_seq_num, r_seq_num} ->
        assert store.seq_to_timestamp[r_seq_num] >= store.seq_to_timestamp[l_seq_num]
      end)
    end

    test "handles rollover when receiving packets from the next cycle", %{store: store} do
      store =
        [@max_seq_number - 1, @max_seq_number, 0, 1, 2]
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      sequence_numbers = get_sequence_numbers(store)

      expected_sequence_numbers =
        [
          @max_seq_number - 1,
          @max_seq_number,
          @max_seq_number + 1,
          @max_seq_number + 2,
          @max_seq_number + 3
        ]
        |> MapSet.new()

      assert MapSet.equal?(sequence_numbers, expected_sequence_numbers)
      assert store.base_seq_num == @max_seq_number - 1
      assert store.max_seq_num == @max_seq_number + 3
    end

    test "handles rollover when receiving packets from the previous cycle", %{store: store} do
      store =
        [0, 1, @max_seq_number - 1, @max_seq_number, 2]
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      sequence_numbers = get_sequence_numbers(store)

      expected_sequence_numbers =
        [
          @max_seq_number + 1,
          @max_seq_number + 2,
          @max_seq_number - 1,
          @max_seq_number,
          @max_seq_number + 3
        ]
        |> MapSet.new()

      assert MapSet.equal?(sequence_numbers, expected_sequence_numbers)
      assert store.base_seq_num == @max_seq_number - 1
      assert store.max_seq_num == @max_seq_number + 3
    end

    test "preserves timestamps for sequence numbers added before rollover", %{store: store} do
      sequence_numbers_before_rollover = [
        @max_seq_number - 2,
        @max_seq_number - 1,
        @max_seq_number
      ]

      store =
        sequence_numbers_before_rollover
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      store_after_rollover = PacketInfoStore.insert_packet_info(store, 0)

      sequence_numbers_before_rollover
      |> Enum.each(fn seq_num ->
        assert store.seq_to_timestamp[seq_num] == store_after_rollover.seq_to_timestamp[seq_num]
      end)
    end

    test "preserves timestamps for sequence numbers shifted due to rollover", %{store: store} do
      sequence_numbers_before_rollover = [0, 1, 2]

      store =
        sequence_numbers_before_rollover
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))

      store_after_rollover = PacketInfoStore.insert_packet_info(store, @max_seq_number)

      sequence_numbers_before_rollover
      |> Enum.each(fn seq_num ->
        assert store.seq_to_timestamp[seq_num] ==
                 store_after_rollover.seq_to_timestamp[seq_num + @max_seq_number + 1]
      end)
    end
  end

  describe "When requesting stats, PacketInfoStore" do
    setup %{store: store} do
      stats =
        [1, 0, @max_seq_number - 2, @max_seq_number, 2, @max_seq_number - 1]
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))
        |> PacketInfoStore.get_stats()

      [stats: stats, store: store]
    end

    test "makes reference time divisible by 64ms", %{stats: stats} do
      ref_time_as_ms = stats.reference_time |> Membrane.Time.as_milliseconds()

      assert is_integer(ref_time_as_ms)
      assert rem(ref_time_as_ms, 64) == 0
    end

    test "makes receive delta for each packet status", %{stats: stats} do
      %{
        packet_status_count: packet_status_count,
        receive_deltas: receive_deltas
      } = stats

      assert packet_status_count == 6
      assert packet_status_count == length(receive_deltas)
    end

    test "handles non-received packets", %{store: store} do
      discontinued_sequence_numbers = [0, 4, 5, 7, 8]
      lost_sequence_numbers = [1, 2, 3, 6]

      %{
        packet_status_count: packet_status_count,
        receive_deltas: receive_deltas
      } =
        discontinued_sequence_numbers
        |> Enum.reduce(store, &PacketInfoStore.insert_packet_info(&2, &1))
        |> PacketInfoStore.get_stats()

      assert packet_status_count == 9
      assert packet_status_count == length(receive_deltas)

      Enum.each(lost_sequence_numbers, fn seq_num ->
        assert Enum.at(receive_deltas, seq_num) == :not_received
      end)

      assert Enum.count(receive_deltas, &(&1 == :not_received)) == length(lost_sequence_numbers)
    end
  end

  defp get_sequence_numbers(%{seq_to_timestamp: seq_to_timestamp}) do
    seq_to_timestamp |> Map.keys() |> MapSet.new()
  end
end
