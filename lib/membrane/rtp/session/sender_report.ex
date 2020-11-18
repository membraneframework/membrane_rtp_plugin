defmodule Membrane.RTP.Session.SenderReport do
  alias Membrane.{RTP, RTCP, Time}

  defmodule Data do
    @type t :: %__MODULE__{
            senders_ssrcs: MapSet.t(RTP.ssrc_t()),
            stats: %{
              RTP.ssrc_t() => RTP.Serializer.Stats.t()
            }
          }

    defstruct senders_ssrcs: MapSet.new(),
              stats: %{}
  end

  @type maybe_report_t :: {:report, RTCP.CompoundPacket.t()} | :no_report

  @spec init_report(senders :: MapSet.t(RTP.ssrc_t()), data :: Data.t()) ::
          {MapSet.t(RTP.ssrc_t()), Data.t()}
  def init_report(senders, %Data{senders_ssrcs: senders_ssrcs} = data)
      when senders_ssrcs == %MapSet{} do
    senders_stats =
      data.stats |> Bunch.KVEnum.filter_by_keys(&MapSet.member?(senders, &1)) |> Map.new()

    data = %{
      data
      | senders_ssrcs: senders,
        stats: senders_stats
    }

    {senders, data}
  end

  @spec flush_report(data :: Data.t()) :: maybe_report_t()
  def flush_report(data) do
    if Enum.empty?(data.senders_ssrcs) do
      {:no_report, data}
    else
      {{:report, generate_report(data.stats)}, %{data | senders_ssrcs: MapSet.new(), stats: %{}}}
    end
  end


  def handle_stats(stats, sender_ssrc, data) do
    senders_ssrcs = MapSet.delete(data.senders_ssrcs, sender_ssrc)
    
  end

  defp generate_report(stats) do
    %RTCP.CompoundPacket{
      packets:
        Enum.flat_map(stats, fn {sender_ssrc, sender_stats} ->
          generate_sender_report(sender_ssrc, sender_stats)
        end)
    }
  end

  defp generate_sender_report(sender_ssrc, sender_stats) do
    timestamp = Time.os_time()
    sender_info = %{
      wallclock_timestamp: Time.to_ntp_timestamp(timestamp),
      rtp_timestamp: timestamp,
      sender_packet_count: sender_stats.sender_packet_count,
      sender_octet_count: sender_stats.sender_octet_count
    }

    [%RTCP.SenderReportPacket{ssrc: sender_ssrc, reports: [], sender_info: sender_info}]
  end
end
