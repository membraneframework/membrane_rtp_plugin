defmodule Membrane.RTCP.Receiver do
  @moduledoc """
  Element exchanging RTCP packets and RTCP receiver statistics.
  """
  use Membrane.Filter

  alias Membrane.RTCPEvent
  alias Membrane.RTCP.{FeedbackPacket, SenderReportPacket}
  alias Membrane.{RTCP, RTP}
  alias Membrane.RTCP.ReceiverReport
  alias Membrane.Time

  require Membrane.Logger
  require Membrane.TelemetryMetrics

  def_input_pad :input, caps: :any, demand_mode: :auto
  def_output_pad :output, caps: :any, demand_mode: :auto

  def_options local_ssrc: [spec: RTP.ssrc_t()],
              remote_ssrc: [spec: RTP.ssrc_t()],
              report_interval: [spec: Membrane.Time.t() | nil, default: nil],
              fir_interval: [spec: Membrane.Time.t() | nil, default: nil],
              telemetry_metadata: [spec: [{atom(), any()}], default: []]

  @event_name [:sending_fir, :rtcp]

  @impl true
  def handle_init(opts) do
    {:ok, Map.from_struct(opts) |> Map.merge(%{fir_seq_num: 0, sr_info: %{}})}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    fir_timer =
      if state.fir_interval, do: [start_timer: {:fir_timer, state.fir_interval}], else: []

    report_timer =
      if state.report_interval,
        do: [start_timer: {:report_timer, state.report_interval}],
        else: []

    Membrane.TelemetryMetrics.register_event_with_telemetry_metadata(
      @event_name,
      state.telemetry_metadata
    )

    {{:ok, fir_timer ++ report_timer}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    fir_timer = if state.fir_interval, do: [stop_timer: :fir_timer], else: []
    report_timer = if state.report_interval, do: [stop_timer: :report_timer], else: []
    {{:ok, fir_timer ++ report_timer}, state}
  end

  @impl true
  def handle_tick(:report_timer, _ctx, state) do
    {{:ok, event: {:output, %ReceiverReport.StatsRequestEvent{}}}, state}
  end

  @impl true
  def handle_tick(:fir_timer, _ctx, state) do
    send_fir(state)
  end

  @impl true
  def handle_event(:input, %RTCPEvent{rtcp: %SenderReportPacket{} = rtcp} = event, _ctx, state) do
    <<_wallclock_ts_upper_16_bits::16, wallclock_ts_middle_32_bits::32,
      _wallclock_ts_lower_16_bits::16>> =
      Time.to_ntp_timestamp(rtcp.sender_info.wallclock_timestamp)

    sr_info = %{
      cut_wallclock_ts: wallclock_ts_middle_32_bits,
      arrival_ts: event.arrival_timestamp
    }

    {:ok, %{state | sr_info: sr_info}}
  end

  @impl true
  def handle_event(:input, %RTCPEvent{}, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(:output, %ReceiverReport.StatsEvent{stats: :no_stats}, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(:output, %ReceiverReport.StatsEvent{stats: stats}, _ctx, state) do
    now = Time.vm_time()
    delay_since_sr = now - Map.get(state.sr_info, :arrival_ts, now)

    report_block = %RTCP.ReportPacketBlock{
      ssrc: state.remote_ssrc,
      fraction_lost: stats.fraction_lost,
      total_lost: stats.total_lost,
      highest_seq_num: stats.highest_seq_num,
      interarrival_jitter: trunc(stats.interarrival_jitter),
      last_sr_timestamp: Map.get(state.sr_info, :cut_wallclock_ts, 0),
      # delay_since_sr is expressed in 1/65536 seconds, see https://tools.ietf.org/html/rfc3550#section-6.4.1
      delay_since_sr: Time.to_seconds(65_536 * delay_since_sr)
    }

    packet = %RTCP.ReceiverReportPacket{ssrc: state.local_ssrc, reports: [report_block]}
    {{:ok, event: {:input, %RTCPEvent{rtcp: packet}}}, state}
  end

  @impl true
  def handle_event(:output, %Membrane.KeyframeRequestEvent{}, _ctx, state) do
    send_fir(state)
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  defp send_fir(state) do
    rtcp = %FeedbackPacket{
      origin_ssrc: state.local_ssrc,
      payload: %FeedbackPacket.FIR{
        target_ssrc: state.remote_ssrc,
        seq_num: state.fir_seq_num
      }
    }

    Membrane.TelemetryMetrics.execute(
      @event_name,
      %{},
      %{
        ssrc: state.remote_ssrc,
        telemetry_metadata: state.telemetry_metadata
      }
    )

    event = %RTCPEvent{rtcp: rtcp}
    state = Map.update!(state, :fir_seq_num, &(&1 + 1))
    {{:ok, event: {:input, event}}, state}
  end
end
