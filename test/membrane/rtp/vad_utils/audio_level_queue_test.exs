defmodule Membrane.RTP.VadUtils.AudioLevelQueueTest do
  @moduledoc """
  AudioLevelQueue api tests.
  """

  use ExUnit.Case

  alias Membrane.RTP.VadUtils.AudioLevelQueue

  @params Application.compile_env(
            :membrane_rtp_plugin,
            :vad_estimation_parameters
          )

  @immediate @params[:immediate]
  @medium @params[:medium]
  @long @params[:long]

  @target_levels_length @immediate[:subunits] * @medium[:subunits] * @long[:subunits]

  describe "new" do
    test "creates new queue" do
      queue = AudioLevelQueue.new()

      assert %AudioLevelQueue{levels: levels, length: length} = queue
      assert :queue.len(levels) == 0
      assert length == 0
    end
  end

  describe "add" do
    setup do
      %{empty_queue: AudioLevelQueue.new()}
    end

    test "Adds new element", %{empty_queue: empty_queue} do
      level = 90

      queue_with_element = AudioLevelQueue.add(empty_queue, level)

      assert AudioLevelQueue.to_list(queue_with_element) == [90]
      assert AudioLevelQueue.len(queue_with_element) == 1
    end

    test "Trims the queue if needed", %{empty_queue: empty_queue} do
      an_arbitrary_number = 42
      levels = List.duplicate(90, @target_levels_length + an_arbitrary_number)

      queue_with_added_items =
        Enum.reduce(levels, empty_queue, fn x, queue -> AudioLevelQueue.add(queue, x) end)

      assert AudioLevelQueue.len(queue_with_added_items) == @target_levels_length
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

  describe "from list" do
    test "Creates audio level queue out of an empty list" do
      actual_queue = AudioLevelQueue.from_list([])

      assert AudioLevelQueue.len(actual_queue) == 0
    end

    test "Creates audio level queue out of full list set" do
      expected_list = [2, 1, 3, 7]
      actual_queue = AudioLevelQueue.from_list(expected_list)

      assert AudioLevelQueue.len(actual_queue) == 4
      assert AudioLevelQueue.to_list(actual_queue) == expected_list
    end
  end

  describe "len" do
    test "Returns the proper length of a list" do
      queue = AudioLevelQueue.new()
      assert AudioLevelQueue.len(queue) == 0

      queue_with_elements = AudioLevelQueue.from_list([10, 20, 30, 40, 50])
      assert AudioLevelQueue.len(queue_with_elements) == 5
    end
  end
end
