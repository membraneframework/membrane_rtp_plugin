defmodule Membrane.RTP.SequenceNumberTrackerTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.SequenceNumberTracker, as: Tracker

  describe "track/2" do
    test "continuous sequence" do
      tracker = Tracker.new()
      assert {1, 10, tracker} = Tracker.track(tracker, 10)
      assert {1, 11, tracker} = Tracker.track(tracker, 11)
      assert {1, 12, _tracker} = Tracker.track(tracker, 12)
    end

    test "numbers starting at 0" do
      tracker = Tracker.new()
      assert {1, 65_536, tracker} = Tracker.track(tracker, 0)
      assert {1, 65_537, tracker} = Tracker.track(tracker, 1)
      assert {1, 65_538, _tracker} = Tracker.track(tracker, 2)
    end

    test "numbers starting at 65_535" do
      tracker = Tracker.new()
      assert {1, 65_535, tracker} = Tracker.track(tracker, 65_535)
      assert {1, 65_536, tracker} = Tracker.track(tracker, 0)
      assert {1, 65_537, _tracker} = Tracker.track(tracker, 1)
    end

    test "rollover" do
      tracker = Tracker.new()
      assert {1, 65_533, tracker} = Tracker.track(tracker, 65_533)
      assert {1, 65_534, tracker} = Tracker.track(tracker, 65_534)
      assert {1, 65_535, tracker} = Tracker.track(tracker, 65_535)
      assert {1, 65_536, tracker} = Tracker.track(tracker, 0)
      assert {1, 65_537, _tracker} = Tracker.track(tracker, 1)
    end

    test "gap" do
      tracker = Tracker.new()
      assert {1, 10, tracker} = Tracker.track(tracker, 10)
      assert {3, 13, tracker} = Tracker.track(tracker, 13)
      assert {1, 14, _tracker} = Tracker.track(tracker, 14)
    end

    test "late sequence number" do
      tracker = Tracker.new()
      assert {1, 10, tracker} = Tracker.track(tracker, 10)
      assert {-1, 9, tracker} = Tracker.track(tracker, 9)
      assert {2, 12, tracker} = Tracker.track(tracker, 12)
      assert {1, 13, _tracker} = Tracker.track(tracker, 13)
    end

    test "gap and late at rollover" do
      tracker = Tracker.new()
      assert {1, 65_533, tracker} = Tracker.track(tracker, 65_533)
      assert {1, 65_534, tracker} = Tracker.track(tracker, 65_534)
      assert {3, 65_537, tracker} = Tracker.track(tracker, 1)
      assert {-3, 65_534, _tracker} = Tracker.track(tracker, 65_534)
    end

    test "repeated number" do
      tracker = Tracker.new()
      assert {1, 10, tracker} = Tracker.track(tracker, 10)
      assert {0, 10, tracker} = Tracker.track(tracker, 10)
      assert {1, 11, tracker} = Tracker.track(tracker, 11)
      assert {0, 11, _tracker} = Tracker.track(tracker, 11)
    end
  end
end
