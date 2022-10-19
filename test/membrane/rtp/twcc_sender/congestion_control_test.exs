defmodule Membrane.RTP.TWCCSender.CongestionControlTest do
  use ExUnit.Case, async: true

  alias Membrane.Time
  alias Membrane.RTP.TWCCSender.CongestionControl

  defp simulate_updates(cc, [], [], [], [], []), do: cc

  defp simulate_updates(
         cc,
         [reference_time | remaining_reference_times],
         [receive_deltas | remaining_receive_deltas],
         [send_deltas | remaining_send_deltas],
         [packet_sizes | remaining_packet_sizes],
         [rtt | remaining_rtts]
       ) do
    IO.inspect({cc.state, cc.a_hat})
    Process.sleep(200)

    simulate_updates(
      CongestionControl.update(
        cc,
        reference_time,
        receive_deltas,
        send_deltas,
        packet_sizes,
        rtt
      ),
      remaining_reference_times,
      remaining_receive_deltas,
      remaining_send_deltas,
      remaining_packet_sizes,
      remaining_rtts
    )
  end

  defp make_fixtures(target_bandwidth, n_reports, packets_per_report, report_interval_ms) do
    reference_times = Enum.map(0..(n_reports - 1), &(Time.milliseconds(report_interval_ms) * &1))

    send_deltas =
      Time.millisecond()
      |> List.duplicate(n_reports * packets_per_report)
      |> Enum.chunk_every(packets_per_report)

    avg_packet_size = target_bandwidth / (report_interval_ms / 1000) / packets_per_report

    packet_sizes =
      avg_packet_size
      |> round()
      |> List.duplicate(n_reports * packets_per_report)
      |> Enum.chunk_every(packets_per_report)

    rtts = 30 |> Time.milliseconds() |> List.duplicate(n_reports)

    {reference_times, send_deltas, packet_sizes, rtts}
  end

  setup_all do
    # 0ms threshold allows us to converge faster in the synthetic test scenario
    [cc: %CongestionControl{signal_time_threshold: 0}]
  end

  describe "Delay-based controller" do
    setup %{cc: %CongestionControl{a_hat: target_bandwidth} = cc} do
      # Setup:
      # 20 reports delivered in a regular 200ms interval -> simulating 4s of bandwidth estimation process
      packet_size = 1200 * 8
      n_reports = 132
      report_interval_ms = 30

      packets_per_report = round(target_bandwidth / packet_size * (report_interval_ms / 1000)) |> IO.inspect(label: :packets_per_report)

      {reference_times, send_deltas, packet_sizes, rtts} =
        make_fixtures(target_bandwidth, n_reports, packets_per_report, report_interval_ms)

      [
        cc: cc,
        n_reports: n_reports,
        packets_per_report: packets_per_report,
        reference_times: reference_times,
        send_deltas: send_deltas,
        packet_sizes: packet_sizes,
        rtts: rtts
      ]
    end

    test "increases estimated receive bandwidth when interpacket delay is constant", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      reference_times: reference_times,
      send_deltas: send_deltas,
      packet_sizes: packet_sizes,
      rtts: rtts
    } do
      receive_deltas =
        Time.milliseconds(5)
        |> List.duplicate(n_reports)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end

    @tag :debug
    test "decreases estimated receive bandwidth if interpacket delay increases", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      reference_times: reference_times,
      send_deltas: send_deltas,
      packet_sizes: packet_sizes,
      rtts: rtts
    } do
      receive_deltas =
        1..n_reports
        |> Enum.map(&Time.milliseconds/1)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.state == :decrease
      assert cc.a_hat < initial_bwe
    end

    test "starts to increase estimated receive bandwidth if interpacket delay decreases", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      reference_times: reference_times,
      send_deltas: send_deltas,
      packet_sizes: packet_sizes,
      rtts: rtts
    } do
      receive_deltas =
        n_reports..1//-1
        |> Enum.map(&Time.milliseconds/1)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end
  end

  describe "Loss-based controller" do
    setup %{cc: %CongestionControl{as_hat: target_bandwidth} = cc} do
      # Setup:
      # 10 reports delivered in a regular 200ms interval -> simulating 2s of bandwidth estimation process
      # 100 packets per report gives us 500 packets/s
      n_reports = 10
      packets_per_report = 100
      report_interval_ms = 200

      {reference_times, send_deltas, packet_sizes, rtts} =
        make_fixtures(target_bandwidth, n_reports, packets_per_report, report_interval_ms)

      [
        cc: cc,
        n_reports: n_reports,
        packets_per_report: packets_per_report,
        reference_times: reference_times,
        send_deltas: send_deltas,
        packet_sizes: packet_sizes,
        rtts: rtts
      ]
    end

    test "decreases estimated send-side bandwidth if fraction lost is high enough", %{
      cc: %CongestionControl{as_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      rtts: rtts,
      reference_times: reference_times,
      send_deltas: send_deltas,
      packet_sizes: packet_sizes
    } do
      fraction_lost = 0.15
      packets_delivered = floor((1 - fraction_lost) * packets_per_report)
      packets_lost = ceil(fraction_lost * packets_per_report)

      receive_deltas =
        (List.duplicate(Time.milliseconds(5), packets_delivered) ++
           List.duplicate(:not_received, packets_lost))
        |> Enum.shuffle()
        |> List.duplicate(n_reports)

      cc =
        simulate_updates(
          cc,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.as_hat < initial_bwe
    end

    test "does not modify estimated send-side bandwidth if fraction lost is moderate", %{
      cc: %CongestionControl{as_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      rtts: rtts,
      reference_times: reference_times,
      send_deltas: send_deltas,
      packet_sizes: packet_sizes
    } do
      fraction_lost = 0.05
      packets_delivered = floor((1 - fraction_lost) * packets_per_report)
      packets_lost = ceil(fraction_lost * packets_per_report)

      receive_deltas =
        (List.duplicate(Time.milliseconds(5), packets_delivered) ++
           List.duplicate(:not_received, packets_lost))
        |> Enum.shuffle()
        |> List.duplicate(n_reports)

      cc =
        simulate_updates(
          cc,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert_in_delta cc.as_hat, initial_bwe, 0.01 * initial_bwe
    end

    test "increases estimated send-side bandwidth if fraction lost is small enough", %{
      cc: %CongestionControl{as_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      rtts: rtts,
      reference_times: reference_times,
      send_deltas: send_deltas,
      packet_sizes: packet_sizes
    } do
      fraction_lost = 0.01
      packets_delivered = floor((1 - fraction_lost) * packets_per_report)
      packets_lost = ceil(fraction_lost * packets_per_report)

      receive_deltas =
        (List.duplicate(Time.milliseconds(5), packets_delivered) ++
           List.duplicate(:not_received, packets_lost))
        |> Enum.shuffle()
        |> List.duplicate(n_reports)

      cc =
        simulate_updates(
          cc,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.as_hat > initial_bwe
    end
  end
end
