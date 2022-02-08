defmodule Membrane.RTP.TWCCSender.CongestionControlTest do
  use ExUnit.Case, async: true

  alias Membrane.Time
  alias Membrane.RTP.TWCCSender.CongestionControl

  require Bitwise

  defp simulate_updates(cc, [], [], [], []), do: cc

  defp simulate_updates(
         cc,
         [ref_time | mock_ref_times],
         [recv_deltas | mock_recv_deltas],
         [send_deltas | mock_send_deltas],
         [packet_sizes | mock_packet_sizes]
       ) do
    # Some triggers of congestion control module require non-zero time difference between measurements
    Process.sleep(1)

    simulate_updates(
      CongestionControl.update(cc, ref_time, recv_deltas, send_deltas, packet_sizes),
      mock_ref_times,
      mock_recv_deltas,
      mock_send_deltas,
      mock_packet_sizes
    )
  end

  describe "Delay-based controller" do
    setup do
      # Setup:
      # 20 reports delivered in a regular 100ms interval -> simulating 2s of bandwidth estimation process
      # 10 packets per report gives us 100 packets/s
      # Packet sizes are constant and their "sending" rate equals inital bandwidth estimation

      cc = %CongestionControl{signal_time_threshold: 0, target_receive_interval: Time.second()}
      n_reports = 20
      packets_per_report = 10
      report_interval_ms = 200
      avg_packet_size = cc.a_hat / (report_interval_ms / 1000) / packets_per_report

      mock_ref_times = Enum.map(0..(n_reports - 1), &(Time.milliseconds(report_interval_ms) * &1))

      mock_send_deltas =
        Time.millisecond()
        |> List.duplicate(n_reports * packets_per_report)
        |> Enum.chunk_every(packets_per_report)

      mock_packet_sizes =
        avg_packet_size
        |> round()
        |> List.duplicate(n_reports * packets_per_report)
        |> Enum.chunk_every(packets_per_report)

      [
        cc: cc,
        n_reports: n_reports,
        packets_per_report: packets_per_report,
        mock_ref_times: mock_ref_times,
        mock_send_deltas: mock_send_deltas,
        mock_packet_sizes: mock_packet_sizes
      ]
    end

    test "increases estimated receive bandwidth when interpacket delays are low and constant", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      mock_ref_times: mock_ref_times,
      mock_send_deltas: mock_send_deltas,
      mock_packet_sizes: mock_packet_sizes
    } do
      mock_recv_deltas =
        Time.milliseconds(5)
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          mock_ref_times,
          mock_recv_deltas,
          mock_send_deltas,
          mock_packet_sizes
        )

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end

    test "decreases estimated receive bandwidth if interpacket delays increase", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      mock_ref_times: mock_ref_times,
      mock_send_deltas: mock_send_deltas,
      mock_packet_sizes: mock_packet_sizes
    } do
      mock_recv_deltas =
        1..n_reports
        |> Enum.map(&Time.milliseconds/1)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          mock_ref_times,
          mock_recv_deltas,
          mock_send_deltas,
          mock_packet_sizes
        )

      assert cc.state == :decrease
      assert cc.a_hat < 0.75 * initial_bwe
    end

    test "increases estimated receive bandwidth if interpacket delays decrease", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      mock_ref_times: mock_ref_times,
      mock_send_deltas: mock_send_deltas,
      mock_packet_sizes: mock_packet_sizes
    } do
      mock_recv_deltas =
        n_reports..1//-1
        |> Enum.map(&Time.milliseconds/1)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          mock_ref_times,
          mock_recv_deltas,
          mock_send_deltas,
          mock_packet_sizes
        )

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end
  end

  describe "Loss-based controller" do
    setup do
      # Setup:
      # 5 reports delivered in a regular 500ms interval -> simulating 2.5s of bandwidth estimation process
      # 100 packets per report gives us 1000 packets/s
      # Packet sizes are constant and they shouldn't play role in loss-based control

      cc = %CongestionControl{}
      n_reports = 5
      packets_per_report = 100
      report_interval_ms = 500

      mock_ref_times = Enum.map(0..(n_reports - 1), &(Time.milliseconds(report_interval_ms) * &1))

      mock_send_deltas =
        Time.millisecond()
        |> List.duplicate(n_reports * packets_per_report)
        |> Enum.chunk_every(packets_per_report)

      mock_packet_sizes =
        1000
        |> List.duplicate(n_reports * packets_per_report)
        |> Enum.chunk_every(packets_per_report)

      [
        cc: cc,
        n_reports: n_reports,
        packets_per_report: packets_per_report,
        mock_ref_times: mock_ref_times,
        mock_send_deltas: mock_send_deltas,
        mock_packet_sizes: mock_packet_sizes
      ]
    end

    test "decreases estimated send-side bandwidth if fraction lost is high enough", %{
      cc: %CongestionControl{as_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      mock_ref_times: mock_ref_times,
      mock_send_deltas: mock_send_deltas,
      mock_packet_sizes: mock_packet_sizes
    } do
      fraction_lost = 0.2
      packets_delivered = floor((1 - fraction_lost) * packets_per_report)
      packets_lost = ceil(fraction_lost * packets_per_report)

      mock_recv_deltas =
        (List.duplicate(Time.milliseconds(5), packets_delivered) ++
           List.duplicate(:not_received, packets_lost))
        |> Enum.shuffle()
        |> List.duplicate(n_reports)

      cc =
        simulate_updates(
          cc,
          mock_ref_times,
          mock_recv_deltas,
          mock_send_deltas,
          mock_packet_sizes
        )

      assert cc.as_hat < 0.75 * initial_bwe
    end

    test "does not modify estimated send-side bandwidth if fraction lost is moderate", %{
      cc: %CongestionControl{as_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      mock_ref_times: mock_ref_times,
      mock_send_deltas: mock_send_deltas,
      mock_packet_sizes: mock_packet_sizes
    } do
      fraction_lost = 0.05
      packets_delivered = floor((1 - fraction_lost) * packets_per_report)
      packets_lost = ceil(fraction_lost * packets_per_report)

      mock_recv_deltas =
        (List.duplicate(Time.milliseconds(5), packets_delivered) ++
           List.duplicate(:not_received, packets_lost))
        |> Enum.shuffle()
        |> List.duplicate(n_reports)

      cc =
        simulate_updates(
          cc,
          mock_ref_times,
          mock_recv_deltas,
          mock_send_deltas,
          mock_packet_sizes
        )

      assert cc.as_hat == initial_bwe
    end

    test "increases estimated send-side bandwidth if fraction lost is small enough", %{
      cc: %CongestionControl{as_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      mock_ref_times: mock_ref_times,
      mock_send_deltas: mock_send_deltas,
      mock_packet_sizes: mock_packet_sizes
    } do
      fraction_lost = 0.01
      packets_delivered = floor((1 - fraction_lost) * packets_per_report)
      packets_lost = ceil(fraction_lost * packets_per_report)

      mock_recv_deltas =
        (List.duplicate(Time.milliseconds(5), packets_delivered) ++
           List.duplicate(:not_received, packets_lost))
        |> Enum.shuffle()
        |> List.duplicate(n_reports)

      cc =
        simulate_updates(
          cc,
          mock_ref_times,
          mock_recv_deltas,
          mock_send_deltas,
          mock_packet_sizes
        )

      assert cc.as_hat > 1.25 * initial_bwe
    end
  end
end
