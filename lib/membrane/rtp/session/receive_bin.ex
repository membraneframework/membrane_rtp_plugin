defmodule Membrane.RTP.Session.ReceiveBin do
  # TODO: Either rename and add sending support or wrap in a bin handling both receiving and sending
  @moduledoc """
  A bin handling the receive part of RTP session.

  Consumes one or more RTP streams on each input and outputs a stream from one SSRC on each output.

  Every stream is parsed and then (based on SSRC field) RTP streams are separated, depacketized and sent further.
  It notifies its parent about each new stream with a notification of the format `{:new_rtp_stream, ssrc, payload_type}`.
  Parent should then connect to this bin's dynamic output pad instance that will
  have an id == `ssrc`.
  """
  use Membrane.Bin

  require Bitwise
  require Membrane.Logger

  alias Membrane.ParentSpec
  alias Membrane.{RTCP, RTP, Time}
  alias Membrane.RTP.Packet.PayloadType

  @ssrc_boundaries 2..(Bitwise.bsl(1, 32) - 1)

  @bin_input_buffer_params [warn_size: 250, fail_size: 500]

  @known_depayloaders %{
    H264: Membrane.RTP.H264.Depayloader,
    MPA: Membrane.RTP.MPEGAudio.Depayloader
  }

  def_options fmt_mapping: [
                spec: %{RTP.payload_type_t() => {RTP.encoding_name_t(), RTP.clock_rate_t()}},
                default: %{},
                description: "Mapping of the custom payload types ( > 95)"
              ],
              custom_depayloaders: [
                spec: %{RTP.encoding_name_t() => module()},
                default: %{},
                description: "Mapping from a payload type to a custom depayloader module"
              ],
              rtcp_interval: [
                type: :time,
                default: 5 |> Membrane.Time.seconds(),
                description: "Interval between sending subseqent RTCP receiver reports."
              ],
              receiver_ssrc_generator: [
                type: :function,
                spec:
                  (local_ssrcs :: [pos_integer], remote_ssrcs :: [pos_integer] ->
                     ssrc :: pos_integer),
                default: &__MODULE__.generate_receiver_ssrc/2,
                description: """
                Function generating receiver SSRCs. Default one generates random SSRC
                that is not in `local_ssrcs` nor `remote_ssrcs`.
                """
              ]

  @doc false
  def generate_receiver_ssrc(local_ssrcs, remote_ssrcs) do
    fn -> Enum.random(@ssrc_boundaries) end
    |> Stream.repeatedly()
    |> Enum.find(&(&1 not in local_ssrcs and &1 not in remote_ssrcs))
  end

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request
  def_input_pad :rtcp_input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, demand_unit: :buffers, caps: :any, availability: :on_request
  def_output_pad :rtcp_output, demand_unit: :buffers, caps: RTCP, availability: :on_request

  defmodule State do
    @moduledoc false

    defstruct fmt_mapping: %{},
              ssrc_pt_mapping: %{},
              depayloaders: nil,
              ssrcs: %{},
              rtcp_interval: nil,
              receiver_ssrc_generator: nil,
              rtcp_report_data: %{
                ssrcs: MapSet.new(),
                remote_reports: %{},
                stats: []
              }
  end

  @impl true
  def handle_init(options) do
    children = [ssrc_router: RTP.SSRCRouter]
    links = []

    spec = %ParentSpec{children: children, links: links}

    depayloaders = Map.merge(@known_depayloaders, options.custom_depayloaders)

    {{:ok, spec: spec},
     %State{
       fmt_mapping: options.fmt_mapping,
       depayloaders: depayloaders,
       rtcp_interval: options.rtcp_interval,
       receiver_ssrc_generator: options.receiver_ssrc_generator
     }}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, ref) = pad, _ctx, state) do
    parser_ref = {:rtp_parser, ref}

    children = [{parser_ref, RTP.Parser}]

    links = [
      link_bin_input(pad)
      |> via_in(:input, buffer: @bin_input_buffer_params)
      |> to(parser_ref)
      |> to(:ssrc_router)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, ref) = pad, _ctx, state) do
    parser_ref = {:rtcp_parser, ref}

    children = [{parser_ref, RTCP.Parser}]

    links = [
      link_bin_input(pad)
      |> via_in(:input, buffer: @bin_input_buffer_params)
      |> to(parser_ref)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    {pt_name, clock_rate} = state.ssrc_pt_mapping |> Map.get(ssrc)

    depayloader =
      case state.depayloaders[pt_name] do
        nil -> raise "Cannot find depayloader for payload type #{pt_name}"
        depayloader -> depayloader
      end

    rtp_stream_name = {:rtp_stream_bin, ssrc}

    new_children = [
      {rtp_stream_name,
       %RTP.StreamReceiveBin{depayloader: depayloader, ssrc: ssrc, clock_rate: clock_rate}}
    ]

    new_links = [
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc))
      |> to(rtp_stream_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    state = %{state | ssrcs: add_ssrc(ssrc, state.ssrcs, state.receiver_ssrc_generator)}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, _ctx, state) do
    new_children = [receiver_reporter: RTCP.ReceiverReporter]
    new_links = [link(:receiver_reporter) |> to_bin_output(pad)]
    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec, start_timer: {:rtcp_report_timer, state.rtcp_interval}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, ref), _ctx, state) do
    {{:ok, remove_child: {:rtp_parser, ref}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtcp_input, ref), _ctx, state) do
    {{:ok, remove_child: {:rtcp_parser, ref}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, ssrc), _ctx, state) do
    # TODO: parent may not know when to unlink, we need to timout SSRCs and notify about that and BYE packets over RTCP
    state = %{state | ssrcs: Map.delete(state.ssrcs, ssrc)}
    {{:ok, remove_child: {:rtp_stream_bin, ssrc}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtcp_output, _ref), _ctx, state) do
    {{:ok, stop_timer: :rtcp_report_timer, remove_child: :receiver_reporter}, state}
  end

  @impl true
  def handle_tick(:rtcp_report_timer, _ctx, state) do
    %{rtcp_report_data: report_data} = state
    remote_ssrcs = state.ssrcs |> Map.keys() |> MapSet.new()
    forwards = Enum.map(remote_ssrcs, &{{:rtp_stream_bin, &1}, :send_stats})
    actions = Enum.map(forwards, &{:forward, &1})

    actions =
      if Enum.empty?(report_data.ssrcs) do
        actions
      else
        Membrane.Logger.warn(
          "Not received stats from ssrcs: #{Enum.join(report_data.ssrcs, ", ")}"
        )

        [forward: {:receiver_reporter, {:report, generate_report(report_data)}}] ++ actions
      end

    remote_reports =
      report_data.remote_reports
      |> Bunch.KVEnum.filter_by_keys(&MapSet.member?(remote_ssrcs, &1))
      |> Map.new()

    report_data = %{report_data | ssrcs: remote_ssrcs, remote_reports: remote_reports, stats: []}
    {{:ok, actions}, %{state | rtcp_report_data: report_data}}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, pt_num}, :ssrc_router, _ctx, state) do
    %State{ssrc_pt_mapping: ssrc_pt_mapping, fmt_mapping: fmt_map} = state

    {pt_name, clock_rate} =
      if PayloadType.is_dynamic(pt_num) do
        unless Map.has_key?(fmt_map, pt_num) do
          raise "Unknown RTP payload type #{pt_num}"
        end

        fmt_map[pt_num]
      else
        {PayloadType.get_encoding_name(pt_num), PayloadType.get_clock_rate(pt_num)}
      end

    if pt_name == nil do
      raise "Unknown RTP payload type #{pt_num}"
    end

    new_ssrc_pt_mapping = ssrc_pt_mapping |> Map.put(ssrc, {pt_name, clock_rate})

    state = %{state | ssrc_pt_mapping: new_ssrc_pt_mapping}
    {{:ok, notify: {:new_rtp_stream, ssrc, pt_name}}, state}
  end

  @impl true
  def handle_notification({:received_rtcp, rtcp, timestamp}, {:rtcp_parser, _ref}, _ctx, state) do
    # TODO: handle RTCP reports properly
    report_data = handle_remote_report(rtcp, timestamp, state.rtcp_report_data)
    {:ok, %{state | rtcp_report_data: report_data}}
  end

  @impl true
  def handle_notification(
        {:jitter_buffer_stats, stats},
        {:rtp_stream_bin, remote_ssrc},
        ctx,
        state
      ) do
    {result, report_data} = handle_stats(stats, remote_ssrc, state.ssrcs, state.rtcp_report_data)
    state = %{state | rtcp_report_data: report_data}

    case {result, ctx.children} do
      {{:report, report}, %{receiver_reporter: _reporter}} ->
        {{:ok, forward: {:receiver_reporter, {:report, report}}}, state}

      {_result, _children} ->
        {:ok, state}
    end
  end

  defp handle_stats(stats, remote_ssrc, ssrcs, report_data) do
    report_ssrcs = MapSet.delete(report_data.ssrcs, remote_ssrc)

    stats =
      case Map.fetch(ssrcs, remote_ssrc) do
        {:ok, local_ssrc} -> [{local_ssrc, remote_ssrc, stats}]
        :error -> []
      end

    report_data = %{report_data | stats: stats ++ report_data.stats, ssrcs: report_ssrcs}

    if Enum.empty?(report_ssrcs) do
      {{:report, generate_report(report_data)}, report_data}
    else
      {:no_report, report_data}
    end
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

  defp handle_remote_report(%RTCP.CompoundPacket{packets: packets}, timestamp, report_data) do
    Enum.reduce(packets, report_data, &handle_remote_report(&1, timestamp, &2))
  end

  defp handle_remote_report(%RTCP.SenderReportPacket{} = packet, timestamp, report_data) do
    %RTCP.SenderReportPacket{sender_info: %{wallclock_timestamp: wallclock_timestamp}, ssrc: ssrc} =
      packet

    <<_::16, cut_wallclock_timestamp::32, _::16>> = Time.to_ntp_timestamp(wallclock_timestamp)

    put_in(report_data, [:remote_reports, ssrc], %{
      cut_wallclock_timestamp: cut_wallclock_timestamp,
      arrival_time: timestamp
    })
  end

  defp handle_remote_report(_packet, _timestamp, state) do
    state
  end

  defp add_ssrc(remote_ssrc, ssrcs, generator) do
    local_ssrc = generator.([remote_ssrc | Map.keys(ssrcs)], Map.values(ssrcs))
    Map.put(ssrcs, remote_ssrc, local_ssrc)
  end
end
