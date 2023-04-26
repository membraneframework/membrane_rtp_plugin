defmodule Membrane.RTP.Vad.AudioLevelQueueTest do
  @moduledoc """
  AudioLevelQueue api tests.
  """

  use ExUnit.Case

  alias Membrane.RTP.Vad.{AudioLevelQueue, VadParams}

  @target_levels_length VadParams.target_levels_length()

  describe "new" do
    test "creates new empty queue" do
      queue = AudioLevelQueue.new()

      assert %AudioLevelQueue{levels: levels, length: length} = queue
      assert :queue.len(levels) == 0
      assert length == 0
    end

    test "Creates audio level queue out of full list set" do
      expected_list = [2, 1, 3, 7]
      actual_queue = AudioLevelQueue.new(expected_list)

      assert actual_queue.length == 4
      assert AudioLevelQueue.to_list(actual_queue) == expected_list
    end

    test "Creates a queue no longer than the limit" do
      an_arbitrary_number = 42
      expected_length = @target_levels_length + an_arbitrary_number
      expected_levels = Enum.to_list(1..@target_levels_length)

      input_list = 1..expected_length
      actual_queue = AudioLevelQueue.new(input_list)

      assert actual_queue.length == @target_levels_length
      assert AudioLevelQueue.to_list(actual_queue) == expected_levels
    end
  end

  describe "add" do
    setup do
      %{empty_queue: AudioLevelQueue.new()}
    end

    test "Adds new element", %{empty_queue: empty_queue} do
      level = 90

      queue_with_element = AudioLevelQueue.add(empty_queue, level)

      assert queue_with_element.length == 1
      assert AudioLevelQueue.to_list(queue_with_element) == [90]
    end

    test "Trims the queue if needed", %{empty_queue: empty_queue} do
      an_arbitrary_number = 42
      levels = List.duplicate(90, @target_levels_length + an_arbitrary_number)

      queue_with_added_items =
        Enum.reduce(levels, empty_queue, fn x, queue -> AudioLevelQueue.add(queue, x) end)

      assert queue_with_added_items.length == @target_levels_length
    end
  end

  describe "to list" do
    test "Creates empty list from an empty queue" do
      assert AudioLevelQueue.to_list(AudioLevelQueue.new()) == []
    end

    test "Creates a list from a queue" do
      list_from_queue =
        AudioLevelQueue.new()
        |> AudioLevelQueue.add(2)
        |> AudioLevelQueue.add(1)
        |> AudioLevelQueue.add(3)
        |> AudioLevelQueue.add(7)
        |> AudioLevelQueue.to_list()

      assert list_from_queue == [7, 3, 1, 2]
    end
  end
end
