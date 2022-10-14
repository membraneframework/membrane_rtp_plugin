defmodule Membrane.RTCP.NACKTrackerTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.NACKTracker

  test "to_send returns sequence numbers reflecting gaps" do
    ref_time = 0
    ms = Membrane.Time.milliseconds(1)

    assert tracker = NACKTracker.new() |> NACKTracker.gap(42..45, ref_time)
    assert NACKTracker.to_send(tracker, ref_time) == []
    assert NACKTracker.to_send(tracker, ref_time + 10 * ms) == Enum.to_list(42..45)

    assert tracker = NACKTracker.received(tracker, 42)
    assert NACKTracker.to_send(tracker, ref_time + 10 * ms) == Enum.to_list(43..45)

    assert tracker = NACKTracker.received(tracker, 44)
    assert NACKTracker.to_send(tracker, ref_time + 10 * ms) == [43, 45]

    assert tracker = NACKTracker.gap(tracker, 46..46, ref_time + 5 * ms)
    assert NACKTracker.to_send(tracker, ref_time + 10 * ms) == [43, 45]
    assert NACKTracker.to_send(tracker, ref_time + 15 * ms) == [43, 45, 46]
  end

  test "update_nacked affects to_send result" do
    ref_time = 0
    ms = Membrane.Time.milliseconds(1)

    tracker =
      NACKTracker.new()
      |> NACKTracker.gap(42..45, ref_time)
      |> NACKTracker.gap(46..47, ref_time + 5 * ms)

    assert to_send = NACKTracker.to_send(tracker, ref_time + 10 * ms)
    assert tracker = NACKTracker.updated_nacked(tracker, to_send, ref_time + 10 * ms)
    assert NACKTracker.to_send(tracker, ref_time + 10 * ms) == []
    assert NACKTracker.to_send(tracker, ref_time + 15 * ms) == [46, 47]
    # TODO: test 42..45 send time and muiltiple updates
  end

  test "setting rtt affects to_send results for seq_nums nacked at least once" do
    ref_time = 0
    ms = Membrane.Time.milliseconds(1)

    tracker =
      NACKTracker.new()
      |> NACKTracker.gap(42..45, ref_time)
      |> NACKTracker.updated_nacked(42..45, ref_time)

    # TODO: set_rtt should not affect not nacked seq_nums

    # TODO: This assumes backoff params
    assert NACKTracker.to_send(tracker, ref_time + 20 * ms) == Enum.to_list(42..45)
    assert tracker = NACKTracker.set_rtt(tracker, 40 * ms)
    assert NACKTracker.to_send(tracker, ref_time + 20 * ms) == []
    assert NACKTracker.to_send(tracker, ref_time + 40 * ms) == Enum.to_list(42..45)

    # Bump attempts
    tracker = NACKTracker.updated_nacked(tracker, 42..45, ref_time)
  end
end
