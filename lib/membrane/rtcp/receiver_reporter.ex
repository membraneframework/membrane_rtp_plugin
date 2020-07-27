defmodule Membrane.RTCP.ReceiverReporter do
  @moduledoc """
  Periodically generates RTCP receive reports basing on jitter buffer stats and RTCP sender reports
  and sends them via output.
  """
  use Membrane.Source
  require Logger
  alias Membrane.{Buffer, RTCP, RTP, Time}

  def_output_pad :output, mode: :push, caps: :any

  def_options interval: [
                type: :time,
                default: 5 |> Time.seconds(),
                description: """
                Time interval between requesting stats for reports.
                Reports are sent when stats are collected.
                """
              ],
              sender_report_timeout: [
                type: :time,
                default: 60 |> Time.seconds(),
                description: """
                Minimal time between receiving RTCP sender report
                and assuming it won't be needed anymore.
                """
              ]

  @impl true
  def handle_init(options) do
    state =
      Map.from_struct(options)
      |> Map.merge(%{ssrcs: MapSet.new(), stats: [], sender_reports: %{}})

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:timer, state.interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: :timer}, state}
  end

  @impl true
  def handle_tick(:timer, _ctx, state) do
    actions =
      if Enum.empty?(state.ssrcs) do
        []
      else
        Logger.warn("Not received stats from ssrcs: #{Enum.join(state.ssrcs, ", ")}")
        [buffer: {:output, %Buffer{payload: make_report(state)}}]
      end
      
      actions = actions ++ [notify: :send_stats]

    time = Time.monotonic_time()

    sender_reports =
      state.sender_reports
      |> Enum.filter(fn {_ssrc, %{time: report_time}} ->
        time - report_time < state.sender_report_timeout
      end)
      |> Map.new()

    state = %{state | ssrcs: MapSet.new(), stats: [], sender_reports: sender_reports}
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:ssrcs, %MapSet{} = ssrcs}, _ctx, state) do
    {:ok, %{state | ssrcs: ssrcs}}
  end

  @impl true
  def handle_other({:stats, stats}, _ctx, state) do
    {local_ssrc, remote_ssrc, %RTP.JitterBuffer.Stats{} = stats} = stats

    state = %{
      state
      | ssrcs: MapSet.delete(state.ssrcs, remote_ssrc),
        stats: [{local_ssrc, remote_ssrc, stats} | state.stats]
    }

    if Enum.empty?(state.ssrcs) do
      buffer = %Buffer{payload: make_report(state)}
      {{:ok, buffer: {:output, buffer}}, %{state | stats: []}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_other({:rtcp, rtcp}, _ctx, state) do
    state = handle_rtcp(rtcp, state)
    {:ok, state}
  end

  defp make_report(state) do
    %RTCP.CompoundPacket{
      packets: Enum.flat_map(state.stats, &generate_receiver_report(&1, state.sender_reports))
    }
    |> RTCP.CompoundPacket.to_binary()
  end

  defp generate_receiver_report(
         {_local_ssrc, _remote_ssrc, %RTP.JitterBuffer.Stats{highest_seq_num: nil}},
         _sender_reports
       ) do
    []
  end

  defp generate_receiver_report(
         {local_ssrc, remote_ssrc, %RTP.JitterBuffer.Stats{} = stats},
         sender_reports
       ) do
    time = Time.monotonic_time()
    sender_report = Map.get(sender_reports, remote_ssrc, %{})

    report_block = %RTCP.ReportPacketBlock{
      ssrc: remote_ssrc,
      fraction_lost: stats.fraction_lost,
      total_lost: stats.total_lost,
      highest_seq_num: stats.highest_seq_num,
      interarrival_jitter: stats.interarrival_jitter,
      last_sr_timestamp: Map.get(sender_report, :cut_wallclock_timestamp, 0),
      delay_since_sr: Time.to_seconds(65536 * (time - Map.get(sender_report, :time, time)))
    }

    [%RTCP.ReceiverReportPacket{ssrc: local_ssrc, reports: [report_block]}]
  end

  defp handle_rtcp(%RTCP.CompoundPacket{packets: packets}, state) do
    Enum.reduce(packets, state, &handle_rtcp/2)
  end

  defp handle_rtcp(%RTCP.SenderReportPacket{} = packet, state) do
    %RTCP.SenderReportPacket{sender_info: %{wallclock_timestamp: wallclock_timestamp}, ssrc: ssrc} =
      packet

    <<_::16, cut_wallclock_timestamp::32, _::16>> = Time.to_ntp_timestamp(wallclock_timestamp)

    put_in(state, [:sender_reports, ssrc], %{
      cut_wallclock_timestamp: cut_wallclock_timestamp,
      time: Time.monotonic_time()
    })
  end

  defp handle_rtcp(_packet, state) do
    state
  end
end
