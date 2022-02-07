defmodule Membrane.RTP.TWCCSender.CongestionControlTest do
  use ExUnit.Case, async: true

  alias Membrane.Time
  alias Membrane.RTP.TWCCSender.CongestionControl

  require Bitwise

  setup_all do
    cc = %CongestionControl{signal_time_threshold: 0, target_receive_interval: Time.second()}
    report_interval_ms = 200
    n_reports = 20
    packets_per_report = 10
    packet_size = cc.a_hat / (1000 / report_interval_ms * packets_per_report)

    [
      cc: cc,
      report_interval_ms: report_interval_ms,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      packet_size: packet_size
    ]
  end

  defp test_update(cc, [], [], [], []), do: cc

  defp test_update(
         cc,
         [ref_time | mock_ref_times],
         [recv_deltas | mock_recv_deltas],
         [send_deltas | mock_send_deltas],
         [packet_sizes | mock_packet_sizes]
       ) do
    Process.sleep(1)

    test_update(
      CongestionControl.update(cc, ref_time, recv_deltas, send_deltas, packet_sizes),
      mock_ref_times,
      mock_recv_deltas,
      mock_send_deltas,
      mock_packet_sizes
    )
  end

  describe "When interpacket delay is constant, congestion control module" do
    test "increases estimated receive bandwidth", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      report_interval_ms: report_interval_ms,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      packet_size: packet_size
    } do
      mock_ref_times = Enum.map(1..n_reports, &Time.milliseconds(report_interval_ms * &1))

      mock_recv_deltas =
        Time.milliseconds(3)
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      mock_send_deltas =
        Time.milliseconds(1)
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      mock_packet_sizes =
        packet_size
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc = test_update(cc, mock_ref_times, mock_recv_deltas, mock_send_deltas, mock_packet_sizes)

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end
  end

  describe "When interpacket delay increases, congestion control module" do
    test "decreases estimated receive bandwidth", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      report_interval_ms: report_interval_ms,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      packet_size: packet_size
    } do
      mock_ref_times = Enum.map(1..n_reports, &Time.milliseconds(report_interval_ms * &1))

      mock_recv_deltas =
        1..n_reports
        |> Enum.map(&Time.milliseconds/1)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      mock_send_deltas =
        Time.milliseconds(1)
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      mock_packet_sizes =
        packet_size
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc = test_update(cc, mock_ref_times, mock_recv_deltas, mock_send_deltas, mock_packet_sizes)

      assert cc.state == :decrease
      assert cc.a_hat < 0.75 * initial_bwe
    end

    test "ignores if this was a sudden spike", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      report_interval_ms: report_interval_ms,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      packet_size: packet_size
    } do
      mock_ref_times = Enum.map(1..n_reports, &Time.milliseconds(report_interval_ms * &1))

      mock_recv_deltas =
        Time.milliseconds(3)
        |> List.duplicate(n_reports - 1)
        |> List.insert_at(div(n_reports, 2), Time.milliseconds(20))
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      mock_send_deltas =
        Time.milliseconds(1)
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      mock_packet_sizes =
        packet_size
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc = test_update(cc, mock_ref_times, mock_recv_deltas, mock_send_deltas, mock_packet_sizes)

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end
  end
end
