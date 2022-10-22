defmodule Membrane.RTP.TWCCSender.CongestionControlTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.TWCCSender.CongestionControl
  alias Membrane.Time

  defp simulate_updates(cc, _report_interval, [], [], [], [], []), do: cc

  defp simulate_updates(
         cc,
         report_interval,
         [reference_time | remaining_reference_times],
         [receive_deltas | remaining_receive_deltas],
         [send_deltas | remaining_send_deltas],
         [packet_sizes | remaining_packet_sizes],
         [rtt | remaining_rtts]
       ) do
    last_bandwidth_increase_ts =
      if cc.state == :increase do
        Time.vm_time() - report_interval
      else
        cc.last_bandwidth_increase_ts - report_interval
      end

    cc = %CongestionControl{cc | last_bandwidth_increase_ts: last_bandwidth_increase_ts}

    simulate_updates(
      CongestionControl.update(
        cc,
        reference_time,
        receive_deltas,
        send_deltas,
        packet_sizes,
        rtt
      ),
      report_interval,
      remaining_reference_times,
      remaining_receive_deltas,
      remaining_send_deltas,
      remaining_packet_sizes,
      remaining_rtts
    )
  end

  defp make_fixtures(
         target_bandwidth,
         n_reports,
         packets_per_report,
         report_interval_ms,
         initial_reference_time
       ) do
    reference_times =
      Enum.map(
        0..(n_reports - 1),
        &(initial_reference_time + Time.milliseconds(report_interval_ms) * &1)
      )

    send_deltas =
      Time.millisecond()
      |> List.duplicate(n_reports * packets_per_report)
      |> Enum.chunk_every(packets_per_report)

    avg_packet_size = target_bandwidth * (report_interval_ms / 1000) / packets_per_report

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
    cc = %CongestionControl{signal_time_threshold: 0}

    # simulate initial traffic to calculate first r_hat
    # 10 packets per report gives us 50 packets/s
    packets_per_report = 10
    report_interval_ms = 200
    # +1 because of small send deltas and the way r_hat is calculated
    n_reports = ceil(cc.r_hat.window / Time.milliseconds(report_interval_ms)) + 1

    {reference_times, send_deltas, packet_sizes, rtts} =
      make_fixtures(cc.a_hat, n_reports, packets_per_report, report_interval_ms, 0)

    receive_deltas =
      Time.milliseconds(1)
      |> List.duplicate(n_reports)
      |> Enum.map(&List.duplicate(&1, packets_per_report))

    cc =
      simulate_updates(
        cc,
        Time.milliseconds(report_interval_ms),
        reference_times,
        receive_deltas,
        send_deltas,
        packet_sizes,
        rtts
      )

    assert cc.r_hat.value != nil

    initial_reference_time = List.last(reference_times) + Time.milliseconds(report_interval_ms)

    [cc: cc, initial_reference_time: initial_reference_time]
  end

  describe "Delay-based controller" do
    setup %{
      cc: %CongestionControl{a_hat: target_bandwidth} = cc,
      initial_reference_time: initial_reference_time
    } do
      # Setup:
      # 20 reports delivered in a regular 200ms interval -> simulating 4s of bandwidth estimation process
      # 10 packets per report gives us 50 packets/s
      n_reports = 20
      packets_per_report = 10
      report_interval_ms = 200

      {reference_times, send_deltas, packet_sizes, rtts} =
        make_fixtures(
          target_bandwidth,
          n_reports,
          packets_per_report,
          report_interval_ms,
          initial_reference_time
        )

      [
        cc: cc,
        n_reports: n_reports,
        packets_per_report: packets_per_report,
        report_interval: Time.milliseconds(report_interval_ms),
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
      report_interval: report_interval,
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
          report_interval,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.state == :increase
      assert cc.a_hat > initial_bwe
    end

    test "decreases estimated receive bandwidth if interpacket delay increases", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      report_interval: report_interval,
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
          report_interval,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.state == :decrease
      assert cc.a_hat < initial_bwe
    end

    test "bumps estimated receive bandwidth after aggressive channel overuse", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      report_interval: report_interval,
      reference_times: reference_times,
      send_deltas: send_deltas,
      rtts: rtts
    } do
      # when sending with a rate much higher than the bwe
      # we should finally overuse the connection;
      # this should result in changing the sate to `:decrease`
      # and setting the bwe to 0.85 * r_hat where r_hat is
      # the last receiver bitrate i.e. our bwe should
      # be bumped by a lot

      rate = initial_bwe * 10
      report_interval_ms = Membrane.Time.to_milliseconds(report_interval)
      packet_size = rate * (report_interval_ms / 1000) / packets_per_report

      packet_sizes =
        packet_size
        |> List.duplicate(n_reports * packets_per_report)
        |> Enum.chunk_every(packets_per_report)

      receive_deltas =
        1..n_reports
        |> Enum.map(&Time.milliseconds/1)
        |> Enum.map(&List.duplicate(&1, packets_per_report))

      cc =
        simulate_updates(
          cc,
          report_interval,
          reference_times,
          receive_deltas,
          send_deltas,
          packet_sizes,
          rtts
        )

      assert cc.state == :decrease
      assert cc.a_hat >= 0.80 * rate
      assert cc.a_hat <= 0.95 * rate
    end

    test "starts to increase estimated receive bandwidth if interpacket delay decreases", %{
      cc: %CongestionControl{a_hat: initial_bwe} = cc,
      n_reports: n_reports,
      packets_per_report: packets_per_report,
      report_interval: report_interval,
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
          report_interval,
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
    setup %{
      cc: %CongestionControl{as_hat: target_bandwidth} = cc,
      initial_reference_time: initial_reference_time
    } do
      # Setup:
      # 10 reports delivered in a regular 200ms interval -> simulating 2s of bandwidth estimation process
      # 100 packets per report gives us 500 packets/s
      n_reports = 10
      packets_per_report = 100
      report_interval_ms = 200

      {reference_times, send_deltas, packet_sizes, rtts} =
        make_fixtures(
          target_bandwidth,
          n_reports,
          packets_per_report,
          report_interval_ms,
          initial_reference_time
        )

      [
        cc: cc,
        n_reports: n_reports,
        packets_per_report: packets_per_report,
        report_interval: Time.milliseconds(report_interval_ms),
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
      report_interval: report_interval,
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
          report_interval,
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
      report_interval: report_interval,
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
          report_interval,
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
      report_interval: report_interval,
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
          report_interval,
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
