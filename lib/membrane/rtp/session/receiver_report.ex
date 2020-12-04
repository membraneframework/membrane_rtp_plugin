defmodule Membrane.RTP.Session.ReceiverReport do
  @moduledoc false
  alias Membrane.{RTCP, RTP, Time}
  require Membrane.Logger

  defmodule Data do
    @moduledoc false
    use Bunch.Access

    @type t :: %__MODULE__{
            remote_ssrcs: MapSet.t(RTP.ssrc_t()),
            remote_reports: %{
              RTP.ssrc_t() => %{
                cut_wallclock_timestamp: pos_integer,
                arrival_time: Time.t()
              }
            },
            stats: [{RTP.ssrc_t(), RTP.ssrc_t(), RTP.JitterBuffer.Stats.t()}]
          }
    defstruct remote_ssrcs: MapSet.new(),
              remote_reports: %{},
              stats: []
  end

  @type maybe_report_t :: {:report, RTCP.CompoundPacket.t()} | :no_report

  @spec init_report(ssrcs :: %{RTP.ssrc_t() => RTP.ssrc_t()}, Data.t()) ::
          {MapSet.t(RTP.ssrc_t()), Data.t()}
  def init_report(ssrcs, %{remote_ssrcs: report_ssrcs} = report_data)
      when report_ssrcs == %MapSet{} do
    remote_ssrcs = ssrcs |> Map.keys() |> MapSet.new()

    remote_reports =
      report_data.remote_reports
      |> Bunch.KVEnum.filter_by_keys(&MapSet.member?(remote_ssrcs, &1))
      |> Map.new()

    report_data = %{
      report_data
      | remote_ssrcs: remote_ssrcs,
        remote_reports: remote_reports
    }

    {remote_ssrcs, report_data}
  end

  @spec flush_report(Data.t()) :: {maybe_report_t, Data.t()}
  def flush_report(report_data) do
    if Enum.empty?(report_data.remote_ssrcs) do
      {:no_report, report_data}
    else
      Membrane.Logger.warn("Not received stats from ssrcs: #{Enum.join(report_data.ssrcs, ", ")}")

      {{:report, generate_report(report_data)},
       %{report_data | remote_ssrcs: MapSet.new(), stats: []}}
    end
  end

  @spec handle_stats(
          RTP.JitterBuffer.Stats.t(),
          RTP.ssrc_t(),
          %{RTP.ssrc_t() => RTP.ssrc_t()},
          Data.t()
        ) ::
          {maybe_report_t, Data.t()}
  def handle_stats(stats, remote_ssrc, ssrcs, report_data) do
    report_ssrcs = MapSet.delete(report_data.remote_ssrcs, remote_ssrc)

    stats =
      case Map.fetch(ssrcs, remote_ssrc) do
        {:ok, local_ssrc} -> [{local_ssrc, remote_ssrc, stats}]
        :error -> []
      end

    report_data = %{report_data | stats: stats ++ report_data.stats, remote_ssrcs: report_ssrcs}

    if Enum.empty?(report_ssrcs) do
      {{:report, generate_report(report_data)}, report_data}
    else
      {:no_report, report_data}
    end
  end

  @spec handle_remote_report(
          RTCP.CompoundPacket.t() | RTCP.Packet.t(),
          Membrane.Time.t(),
          Data.t()
        ) :: Data.t()
  def handle_remote_report(%RTCP.CompoundPacket{packets: packets}, timestamp, report_data) do
    Enum.reduce(packets, report_data, &handle_remote_report(&1, timestamp, &2))
  end

  def handle_remote_report(%RTCP.SenderReportPacket{} = packet, timestamp, report_data) do
    %RTCP.SenderReportPacket{sender_info: %{wallclock_timestamp: wallclock_timestamp}, ssrc: ssrc} =
      packet

    <<_::16, cut_wallclock_timestamp::32, _::16>> = Time.to_ntp_timestamp(wallclock_timestamp)

    put_in(report_data, [:remote_reports, ssrc], %{
      cut_wallclock_timestamp: cut_wallclock_timestamp,
      arrival_time: timestamp
    })
  end

  def handle_remote_report(_packet, _timestamp, report_data) do
    report_data
  end

  defp generate_report(%{stats: stats, remote_reports: remote_reports}) do
    %RTCP.CompoundPacket{
      packets: Enum.flat_map(stats, &generate_receiver_report(&1, remote_reports))
    }
  end

  defp generate_receiver_report({_local_ssrc, _remote_ssrc, :no_stats}, _remote_reports) do
    []
  end

  defp generate_receiver_report(stats_entry, remote_reports) do
    {local_ssrc, remote_ssrc, %RTP.JitterBuffer.Stats{} = stats} = stats_entry
    now = Time.vm_time()
    remote_report = Map.get(remote_reports, remote_ssrc, %{})
    delay_since_sr = now - Map.get(remote_report, :arrival_time, now)

    report_block = %RTCP.ReportPacketBlock{
      ssrc: remote_ssrc,
      fraction_lost: stats.fraction_lost,
      total_lost: stats.total_lost,
      highest_seq_num: stats.highest_seq_num,
      interarrival_jitter: trunc(stats.interarrival_jitter),
      last_sr_timestamp: Map.get(remote_report, :cut_wallclock_timestamp, 0),
      # delay_since_sr is expressed in 1/65536 seconds, see https://tools.ietf.org/html/rfc3550#section-6.4.1
      delay_since_sr: Time.to_seconds(65536 * delay_since_sr)
    }

    [%RTCP.ReceiverReportPacket{ssrc: local_ssrc, reports: [report_block]}]
  end
end
