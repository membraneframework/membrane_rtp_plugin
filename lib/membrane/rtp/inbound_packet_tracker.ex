defmodule Membrane.RTP.InboundPacketTracker do
  @moduledoc """
  # FIXME
  """
  # FIXME docs
  use Membrane.Filter

  alias Membrane.RTCP.ReceiverReportStats
  alias Membrane.RTP.SeqNumTracker

  @allowed_reorder 100

  def_options clock_rate: [
                type: :integer,
                spec: Membrane.RTP.clock_rate_t()
              ],
              repair_sequence_numbers?: [
                spec: boolean(),
                default: true,
                description: "Defines if tracker should try to repair packet's sequence number"
              ],
              local_ssrc: [spec: Membrane.RTP.ssrc_t()],
              remote_ssrc: [spec: Membrane.RTP.ssrc_t()],
              rtcp_report_interval: [spec: Membrane.Time.t() | nil]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    state = %{
      seq_num_tracker: Membrane.RTP.SeqNumTracker.new(),
      rtcp_stats_tracker:
        Membrane.RTCP.ReceiverReportStats.new(opts.local_ssrc, opts.remote_ssrc, opts.clock_rate)
    }

    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {diff, extended_sequence_num, tracker} =
      SeqNumTracker.track(state.seq_num_tracker, buffer.metadata.rtp.sequence_number)

    state = %{state | seq_num_tracker: tracker}

    state = %{
      state
      | rtcp_stats_tracker:
          ReceiverReportStats.packet_arrived(state.rtcp_stats_tracker, extended_sequence_num)
    }

    if abs(diff) > @allowed_reorder do
      {:ok, state}
    else
      {{:ok, buffer: {:output, buffer}}, state}
    end
  end
end
