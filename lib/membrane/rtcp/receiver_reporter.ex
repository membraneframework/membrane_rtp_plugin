defmodule Membrane.RTCP.ReceiverReporter do
  use Membrane.Source
  alias Membrane.{Buffer, RTCP, RTP}

  def_output_pad :output, mode: :push, caps: :any

  def_options interval: [default: 5 |> Membrane.Time.seconds()],
              ssrc: []

  @impl true
  def handle_init(options) do
    {:ok, Map.merge(Map.from_struct(options), %{ssrcs: nil, stats: []})}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:timer, state.interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: {:timer, state.interval}}, state}
  end

  @impl true
  def handle_tick(:timer, _ctx, state) do
    {{:ok, notify: :send_stats}, state}
  end

  @impl true
  def handle_other({:ssrcs, %MapSet{} = ssrcs}, _ctx, state) do
    {:ok, %{state | ssrcs: ssrcs}}
  end

  @impl true
  def handle_other({:stats, ssrc, %RTP.JitterBuffer.Stats{} = stats}, _ctx, state) do
    state = %{
      state
      | ssrcs: MapSet.delete(state.ssrcs, ssrc),
        stats: [{ssrc, stats} | state.stats]
    }

    if Enum.empty?(state.ssrcs) do
      {{:ok, buffer: {:output, %Buffer{payload: make_report(state)}}}, %{state | stats: []}}
    else
      {:ok, state}
    end
  end

  defp make_report(state) do
    %RTCP.ReceiverReportPacket{
      ssrc: state.ssrc,
      reports: Enum.flat_map(state.stats, &generate_report_block/1)
    }
    |> RTCP.Packet.to_binary()
  end

  defp generate_report_block({_ssrc, %RTP.JitterBuffer.Stats{highest_seq_num: nil}}) do
    []
  end

  defp generate_report_block({ssrc, %RTP.JitterBuffer.Stats{} = stats}) do
    [
      %RTCP.ReportPacketBlock{
        ssrc: ssrc,
        fraction_lost: stats.fraction_lost,
        total_lost: stats.total_lost,
        highest_seq_num: stats.highest_seq_num,
        interarrival_jitter: stats.interarrival_jitter,
        # TODO: get from inbound RTCP
        last_sr_timestamp: 0,
        # TODO: get from inbound RTCP
        delay_since_sr: 0
      }
    ]
  end
end
