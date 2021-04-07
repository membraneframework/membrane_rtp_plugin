defmodule Membrane.RTP.SessionBin do
  @moduledoc """
  Bin handling one RTP session, that may consist of multiple incoming and outgoing RTP streams.

  ## Incoming streams
  Incoming RTP streams can be connected via `:rtp_input` pads. As each pad can provide multiple RTP streams,
  they are distinguished basing on SSRC. Once a new stream is received, bin sends `t:new_stream_notification_t/0`
  notification, meaning the parent should link `Pad.ref(:output, ssrc)` pad to consuming components. The stream is
  then depayloaded and forwarded via said pad.

  ## Outgoing streams
  To create an RTP stream, the source stream needs to be connected via `Pad.ref(:input, ssrc)` pad and the sink -
  via `Pad.ref(:rtp_output, ssrc)`. At least one of `:encoding` or `:payload_type` options of `:rtp_output` pad
  must be provided too.

  ## Payloaders and depayloaders
  Payloaders are Membrane elements that transform stream so that it can be put into RTP packets, while depayloaders
  work the other way round. Different codecs require different payloaders and depayloaders. Thus, to send or receive
  given codec via this bin, proper payloader/depayloader is needed. Payloaders and depayloaders can be found in
  `membrane_rtp_X_plugin` packages, where X stands for codec name. It's enough when such plugin is added to
  dependencies.

  ## RTCP
  RTCP packets are received via `:rtcp_input` and sent via `:rtcp_output` pad. Only one instance of each of them
  can be linked. RTCP packets should be delivered to each involved peer that supports RTCP.
  """
  use Membrane.Bin

  require Bitwise
  require Membrane.Logger

  alias Membrane.{ParentSpec, RemoteStream, RTCP, RTP, SRTCP, SRTP}
  alias Membrane.RTP.{PayloadFormat, Session}

  @type new_stream_notification_t :: Membrane.RTP.SSRCRouter.new_stream_notification_t()

  @ssrc_boundaries 2..(Bitwise.bsl(1, 32) - 1)

  @rtp_input_buffer_params [warn_size: 250, fail_size: 500]

  def_options fmt_mapping: [
                spec: %{RTP.payload_type_t() => {RTP.encoding_name_t(), RTP.clock_rate_t()}},
                default: %{},
                description: "Mapping of the custom payload types ( > 95)"
              ],
              custom_payloaders: [
                spec: %{RTP.encoding_name_t() => module()},
                default: %{},
                description: "Mapping from encoding names to custom payloader modules"
              ],
              custom_depayloaders: [
                spec: %{RTP.encoding_name_t() => module()},
                default: %{},
                description: "Mapping from encoding names to custom depayloader modules"
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
              ],
              secure?: [
                type: :boolean,
                default: false,
                description: """
                Specifies whether to use SRTP.
                Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
                """
              ],
              srtp_policies: [
                spec: [ExLibSRTP.Policy.t()],
                default: [],
                description: """
                List of SRTP policies to use for decrypting packets. Used only when `secure?` is set to `true`.
                See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ],
              receiver_srtp_policies: [
                spec: [ExLibSRTP.Policy.t()] | nil,
                default: nil,
                description: """
                List of SRTP policies to use for encrypting receiver reports and other receiver RTCP packets.
                Used only when `secure?` is set to `true`.
                Defaults to the value of `srtp_policies`.
                See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ]

  @doc false
  def generate_receiver_ssrc(local_ssrcs, remote_ssrcs) do
    fn -> Enum.random(@ssrc_boundaries) end
    |> Stream.repeatedly()
    |> Enum.find(&(&1 not in local_ssrcs and &1 not in remote_ssrcs))
  end

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_input_pad :rtp_input,
    demand_unit: :buffers,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    availability: :on_request

  def_input_pad :rtcp_input,
    demand_unit: :buffers,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTCP])},
    availability: :on_request

  def_output_pad :output,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      encoding: [
        spec: RTP.encoding_name_t() | nil,
        default: nil,
        description: """
        Encoding name determining depayloader which will be used to produce output stream from RTP stream.
        """
      ],
      clock_rate: [
        spec: integer() | nil,
        default: nil,
        description: """
        Clock rate to use. If not provided, determined from `fmt_mapping` or defaults registered by proper plugins i.e.
        `Membrane.RTP.X.Plugin` where X is the name of codec corresponding to `encoding`.
        """
      ],
      extensions: [
        spec: [:vad],
        default: [],
        description: """
        List of extensions. Currently `:vad` is only supported.
        * `:vad` will turn on Voice Activity Detection mechanism firing appropriate notifications when needed.
        Should be set only for audio tracks. For more information refer to `Membrane.RTP.VAD` module documentation.
        """
      ]
    ]

  def_output_pad :rtp_output,
    demand_unit: :buffers,
    caps: {RemoteStream, type: :packetized, content_format: RTP},
    availability: :on_request,
    options: [
      payload_type: [
        spec: RTP.payload_type_t() | nil,
        default: nil,
        description: """
        Payload type of output stream. If not provided, determined from `:encoding`.
        """
      ],
      encoding: [
        spec: RTP.encoding_name_t() | nil,
        default: nil,
        description: """
        Encoding name of output stream. If not provided, determined from `:payload_type`.
        """
      ],
      clock_rate: [
        spec: integer() | nil,
        default: nil,
        description: """
        Clock rate to use. If not provided, determined from `:payload_type`.
        """
      ]
    ]

  def_output_pad :rtcp_output,
    demand_unit: :buffers,
    caps: {RemoteStream, type: :packetized, content_format: RTCP},
    availability: :on_request

  defmodule State do
    @moduledoc false
    use Bunch.Access

    defstruct fmt_mapping: %{},
              ssrc_pt_mapping: %{},
              payloaders: nil,
              depayloaders: nil,
              ssrcs: %{},
              senders_ssrcs: %MapSet{},
              rtcp_interval: nil,
              receiver_ssrc_generator: nil,
              rtcp_report_data: %Session.ReceiverReport.Data{},
              rtcp_sender_report_data: %Session.SenderReport.Data{},
              secure?: nil,
              srtp_policies: nil,
              receiver_srtp_policies: nil
  end

  @impl true
  def handle_init(options) do
    children = [ssrc_router: RTP.SSRCRouter]
    links = []
    spec = %ParentSpec{children: children, links: links}
    {receiver_srtp_policies, options} = Map.pop(options, :receiver_srtp_policies)
    {fmt_mapping, options} = Map.pop(options, :fmt_mapping)

    fmt_mapping =
      Bunch.Map.map_values(fmt_mapping, fn {encoding_name, clock_rate} ->
        %{encoding_name: encoding_name, clock_rate: clock_rate}
      end)

    state =
      %State{
        receiver_srtp_policies: receiver_srtp_policies || options.srtp_policies,
        fmt_mapping: fmt_mapping
      }
      |> Map.merge(Map.from_struct(options))

    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtp_input, ref) = pad, _ctx, %{secure?: true} = state) do
    parser_ref = {:rtp_parser, ref}
    decryptor_ref = {:srtp_decryptor, ref}

    children = %{
      parser_ref => RTP.Parser,
      decryptor_ref => %SRTP.Decryptor{policies: state.srtp_policies}
    }

    links = [
      link_bin_input(pad, buffer: @rtp_input_buffer_params)
      |> to(decryptor_ref)
      |> to(parser_ref)
      |> to(:ssrc_router)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtp_input, ref) = pad, _ctx, state) do
    parser_ref = {:rtp_parser, ref}

    children = %{parser_ref => RTP.Parser}

    links = [
      link_bin_input(pad, buffer: @rtp_input_buffer_params)
      |> to(parser_ref)
      |> to(:ssrc_router)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, ref) = pad, _ctx, %{secure?: true} = state) do
    parser_ref = {:rtcp_parser, ref}
    decryptor_ref = {:srtcp_decryptor, ref}

    children = %{
      parser_ref => RTCP.Parser,
      decryptor_ref => %SRTCP.Decryptor{policies: state.srtp_policies}
    }

    links = [link_bin_input(pad) |> to(decryptor_ref) |> to(parser_ref)]
    new_spec = %ParentSpec{children: children, links: links}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, ref) = pad, _ctx, state) do
    parser_ref = {:rtcp_parser, ref}
    children = [{parser_ref, RTCP.Parser}]
    links = [link_bin_input(pad) |> to(parser_ref)]
    new_spec = %ParentSpec{children: children, links: links}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, ctx, state) do
    %{encoding: encoding_name, clock_rate: clock_rate, extensions: extensions} =
      ctx.pads[pad].options

    payload_type = Map.fetch!(state.ssrc_pt_mapping, ssrc)

    encoding_name = encoding_name || get_from_register!(:encoding_name, payload_type, state)
    clock_rate = clock_rate || get_from_register!(:clock_rate, payload_type, state)
    depayloader = get_depayloader!(encoding_name, state)

    rtp_stream_name = {:stream_receive_bin, ssrc}

    new_children = %{
      rtp_stream_name => %RTP.StreamReceiveBin{
        depayloader: depayloader,
        ssrc: ssrc,
        clock_rate: clock_rate
      }
    }

    new_links = [
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc))
      |> to(rtp_stream_name)
      |> to_bin_output(pad)
    ]

    {new_children, new_links} =
      if extensions == [:vad] do
        new_children = Map.merge(new_children, %{{:vad, ssrc} => RTP.VAD})

        new_links = [
          link(:ssrc_router)
          |> via_out(Pad.ref(:output, ssrc))
          |> to(rtp_stream_name)
          |> to({:vad, ssrc})
          |> to_bin_output(pad)
        ]

        {new_children, new_links}
      else
        {new_children, new_links}
      end

    new_spec = %ParentSpec{children: new_children, links: new_links}
    state = %{state | ssrcs: add_ssrc(ssrc, state.ssrcs, state.receiver_ssrc_generator)}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, _ctx, %{secure?: true} = state) do
    new_children = [
      srtcp_encryptor: %SRTCP.Encryptor{policies: state.receiver_srtp_policies},
      rtcp_forwarder: RTCP.Forwarder
    ]

    new_links = [link(:rtcp_forwarder) |> to(:srtcp_encryptor) |> to_bin_output(pad)]
    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec, start_timer: {:rtcp_report_timer, state.rtcp_interval}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, _ctx, state) do
    new_children = [rtcp_forwarder: RTCP.Forwarder]
    new_links = [link(:rtcp_forwarder) |> to_bin_output(pad)]
    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec, start_timer: {:rtcp_report_timer, state.rtcp_interval}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(name, ssrc), ctx, state)
      when name in [:input, :rtp_output] do
    pads_present? =
      Map.has_key?(ctx.pads, Pad.ref(:input, ssrc)) and
        Map.has_key?(ctx.pads, Pad.ref(:rtp_output, ssrc))

    if not pads_present? or Map.has_key?(ctx.children, {:stream_send_bin, ssrc}) do
      {:ok, state}
    else
      pad = Pad.ref(:rtp_output, ssrc)
      %{encoding: encoding_name, clock_rate: clock_rate} = ctx.pads[pad].options
      payload_type = get_output_payload_type!(ctx, ssrc)
      encoding_name = encoding_name || get_from_register!(:encoding_name, payload_type, state)
      clock_rate = clock_rate || get_from_register!(:clock_rate, payload_type, state)
      payloader = get_payloader!(encoding_name, state)
      spec = sent_stream_spec(ssrc, payload_type, payloader, clock_rate, state)
      state = %{state | senders_ssrcs: MapSet.put(state.senders_ssrcs, ssrc)}

      {{:ok, spec: spec}, state}
    end
  end

  defp sent_stream_spec(ssrc, payload_type, payloader, clock_rate, %{
         secure?: true,
         srtp_policies: policies
       }) do
    children = %{
      {:stream_send_bin, ssrc} => %RTP.StreamSendBin{
        ssrc: ssrc,
        payload_type: payload_type,
        payloader: payloader,
        clock_rate: clock_rate
      },
      {:srtp_encryptor, ssrc} => %SRTP.Encryptor{policies: policies}
    }

    links = [
      link_bin_input(Pad.ref(:input, ssrc))
      |> to({:stream_send_bin, ssrc})
      |> to({:srtp_encryptor, ssrc})
      |> to_bin_output(Pad.ref(:rtp_output, ssrc))
    ]

    %ParentSpec{children: children, links: links}
  end

  defp sent_stream_spec(ssrc, payload_type, payloader, clock_rate, %{secure?: false}) do
    children = %{
      {:stream_send_bin, ssrc} => %RTP.StreamSendBin{
        ssrc: ssrc,
        payload_type: payload_type,
        payloader: payloader,
        clock_rate: clock_rate
      }
    }

    links = [
      link_bin_input(Pad.ref(:input, ssrc))
      |> to({:stream_send_bin, ssrc})
      |> to_bin_output(Pad.ref(:rtp_output, ssrc))
    ]

    %ParentSpec{children: children, links: links}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtp_input, ref), _ctx, state) do
    children = [rtp_parser: ref] ++ if state.secure?, do: [srtp_decryptor: ref], else: []
    {{:ok, remove_child: children}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtcp_input, ref), _ctx, state) do
    children = [rtcp_parser: ref] ++ if state.secure?, do: [srtcp_decryptor: ref], else: []
    {{:ok, remove_child: children}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, ssrc), _ctx, state) do
    # TODO: parent may not know when to unlink, we need to timout SSRCs and notify about that and BYE packets over RTCP
    state = %{state | ssrcs: Map.delete(state.ssrcs, ssrc)}
    {{:ok, remove_child: {:stream_receive_bin, ssrc}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtcp_output, _ref), _ctx, state) do
    {{:ok, stop_timer: :rtcp_report_timer, remove_child: :rtcp_forwarder}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(name, ssrc), ctx, state)
      when name in [:input, :rtp_output] do
    case Map.fetch(ctx.children, {:stream_send_bin, ssrc}) do
      {:ok, %{terminating?: false}} ->
        state = %{state | senders_ssrcs: MapSet.delete(state.senders_ssrcs, ssrc)}
        {{:ok, remove_child: {:stream_send_bin, ssrc}}, state}

      _result ->
        {:ok, state}
    end
  end

  @impl true
  def handle_tick(:rtcp_report_timer, _ctx, state) do
    {maybe_receiver_report, report_data} =
      Session.ReceiverReport.flush_report(state.rtcp_report_data)

    {remote_ssrcs, report_data} = Session.ReceiverReport.init_report(state.ssrcs, report_data)

    {maybe_sender_report, sender_report_data} =
      Session.SenderReport.flush_report(state.rtcp_sender_report_data)

    {senders_ssrcs, sender_report_data} =
      Session.SenderReport.init_report(state.senders_ssrcs, sender_report_data)

    sender_stats_requests = Enum.map(senders_ssrcs, &{{:stream_send_bin, &1}, :send_stats})
    receiver_stats_requests = Enum.map(remote_ssrcs, &{{:stream_receive_bin, &1}, :send_stats})

    receiver_report_messages =
      case maybe_receiver_report do
        {:report, report} -> [rtcp_forwarder: {:report, report}]
        :no_report -> []
      end

    sender_report_messages =
      case maybe_sender_report do
        {:report, report} -> [rtcp_forwarder: {:report, report}]
        :no_report -> []
      end

    actions =
      Enum.map(
        receiver_report_messages ++
          receiver_stats_requests ++
          sender_report_messages ++
          sender_stats_requests,
        &{:forward, &1}
      )

    {{:ok, actions},
     %{state | rtcp_report_data: report_data, rtcp_sender_report_data: sender_report_data}}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, payload_type}, :ssrc_router, _ctx, state) do
    state = put_in(state.ssrc_pt_mapping[ssrc], payload_type)
    {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}}, state}
  end

  @impl true
  def handle_notification({:received_rtcp, rtcp, timestamp}, {:rtcp_parser, _ref}, _ctx, state) do
    report_data =
      Session.ReceiverReport.handle_remote_report(rtcp, timestamp, state.rtcp_report_data)

    {:ok, %{state | rtcp_report_data: report_data}}
  end

  @impl true
  def handle_notification(
        {:serializer_stats, stats},
        {:stream_send_bin, sender_ssrc},
        ctx,
        state
      ) do
    {result, report_data} =
      Session.SenderReport.handle_stats(stats, sender_ssrc, state.rtcp_sender_report_data)

    {{:ok, forward_action(result, ctx)}, %{state | rtcp_sender_report_data: report_data}}
  end

  @impl true
  def handle_notification(
        {:jitter_buffer_stats, stats},
        {:stream_receive_bin, remote_ssrc},
        ctx,
        state
      ) do
    {result, report_data} =
      Session.ReceiverReport.handle_stats(stats, remote_ssrc, state.ssrcs, state.rtcp_report_data)

    {{:ok, forward_action(result, ctx)}, %{state | rtcp_report_data: report_data}}
  end

  @impl true
  def handle_notification({:vad, _val} = msg, _from, _ctx, state) do
    {{:ok, notify: msg}, state}
  end

  defp forward_action(result, ctx) do
    with {:report, report} <- result,
         true <- Map.has_key?(ctx.children, :rtcp_forwarder) do
      [forward: {:rtcp_forwarder, {:report, report}}]
    else
      _ -> []
    end
  end

  defp add_ssrc(remote_ssrc, ssrcs, generator) do
    local_ssrc = generator.([remote_ssrc | Map.keys(ssrcs)], Map.values(ssrcs))
    Map.put(ssrcs, remote_ssrc, local_ssrc)
  end

  defp get_from_register!(field, pt, state) do
    pt_mapping = get_payload_type_mapping!(pt, state)
    Map.fetch!(pt_mapping, field)
  end

  defp get_payload_type_mapping!(payload_type, state) do
    pt_mapping =
      PayloadFormat.get_payload_type_mapping(payload_type)
      |> Map.merge(state.fmt_mapping[payload_type] || %{})

    if Map.has_key?(pt_mapping, :encoding_name) and Map.has_key?(pt_mapping, :clock_rate) do
      pt_mapping
    else
      raise "Unknown RTP payload type #{payload_type}"
    end
  end

  defp get_payloader!(encoding_name, state) do
    case state.custom_payloaders[encoding_name] || PayloadFormat.get(encoding_name).payloader do
      nil -> raise "Cannot find payloader for encoding #{encoding_name}"
      payloader -> payloader
    end
  end

  defp get_depayloader!(encoding_name, state) do
    case state.custom_depayloaders[encoding_name] || PayloadFormat.get(encoding_name).depayloader do
      nil -> raise "Cannot find depayloader for encoding #{encoding_name}"
      depayloader -> depayloader
    end
  end

  defp get_output_payload_type!(ctx, ssrc) do
    pad = Pad.ref(:rtp_output, ssrc)
    %{payload_type: pt, encoding: encoding} = ctx.pads[pad].options

    unless pt || encoding do
      raise "Neither payload_type nor encoding specified for #{inspect(pad)})"
    end

    pt || PayloadFormat.get(encoding).payload_type ||
      raise "Cannot find default RTP payload type for encoding #{encoding}"
  end
end
