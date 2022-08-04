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
  work the other way round. Different codecs require different payloaders and depayloaders.

  By default `SessionBin` will neither payload nor depayload incoming/outgoing streams, to do so a payloader/depayloader needs to be
  passed via `Pad.ref(:input, ssrc)` and `Pad.ref(:output, ssrc)` pads options.

  Payloading/Depayloading is necessary if we need to somehow transform the streams. If `SessionBin`s main role is to route packets
  then depayloading and payloading processes are redundant.

  Payloaders and depayloaders can be found in `membrane_rtp_X_plugin` packages, where X stands for codec name.
  It's enough when such a plugin is added to dependencies. To determine which payloader/depayloader to use, one can use `Membrane.RTP.PayloadFormatResolver`
  which given an encoding name should resolve to proper payloader/depayloader modules (if those previously have been registered via mentioned plugins).

  For payloading and depayloading, `SessionBin` uses respective bins `Membrane.RTP.PayloaderBin` and `Membrane.RTP.DepayloaderBin`
  which will be spawned once payloader/depayloader are passed explicitly via pads' options.

  #### Important note
  Payloaders and depayloaders are mostly needed when working with external media sources (in different formats than RTP).
  For applications such as an SFU it is not needed to either payload or depayload the RTP stream as we are always dealing with RTP format.
  In such a case, SessionBin will receive payloaded packets and work as a simple proxy just forwarding the packets (and decrypting them if necessary).
  Therefore it is possible to specify in newly added pads if payloaders/depayloaders should be used for the certain stream.

  ## RTCP
  RTCP packets for inbound stream can be provided either in-band or via a separate `rtp_input` pad instance. Corresponding
  receiver report packets will be sent back through `rtcp_receiver_output` with the same id as `rtp_input` for the RTP stream.

  RTCP for outbound stream is not yet supported. # But will be :)
  """
  use Membrane.Bin

  alias Membrane.{ParentSpec, RemoteStream, RTCP, RTP, SRTP}
  alias Membrane.RTP.{PayloadFormat, Session}

  require Bitwise
  require Membrane.Logger

  @type new_stream_notification_t :: Membrane.RTP.SSRCRouter.new_stream_notification_t()

  @typedoc """
  An atom that identifies an RTP extension in the bin. It will be used by the module implementing it
  to mark its header extension under `Membrane.RTP.Header.Extension`'s `identifier` key.
  """
  @type rtp_extension_name_t :: atom()

  @typedoc """
  A module representing an RTP extension that will be spawned and linked just before a newly created
  `:output` pad representing a single RTP stream.

  Given extension config must be a valid `Membrane.Filter`.

  An extension will be spawned inside the bin under `{extension_name, ssrc}` name.

  ### RTP plugin ships with the following extensions:
  * `Membrane.RTP.VAD`
  * `Membrane.RTP.TWCCReceiver`
  * `Membrane.RTP.TWCCSender`

  ### Example usage
  `{:vad, %Mebrane.RTP.VAD{vad_id: 1, time_window: 1_000_000}}`
  `{:twcc, %Mebrane.RTP.TWCCReceiver{twcc_id: 1, report_interval: Membrane.Time.milliseconds(250)}}`
  `{:twcc, Mebrane.RTP.TWCCSender}`

  ### TWCC
  TWCC as a transport-wide extension is handled differently, and is linked from `RTP.SSRCRouter`
  to possibly many `RTP.StreamReceiveBin`s. Only the first TWCC extension is initialized, and it
  will handle all RTP streams that have declared support for it. For outgoing streams, an `RTP.TWCCSender`
  element will be spawned and linked to all `RTP.StreamSendBin`s.
  """
  @type rtp_extension_options_t ::
          {extension_name :: rtp_extension_name_t(),
           extension_config :: Membrane.ParentSpec.child_spec_t()}

  @typedoc """
  A mapping between internally used `rtp_extension_name_t()` and extension identifiers expected by RTP stream receiver.
  """
  @type rtp_extension_mapping_t :: %{rtp_extension_name_t() => 1..14}

  @typedoc """
  A definition of a general extension inside `Membrane.RTP.StreamReceiveBin`. Each extension should
  have just a single input and output pad named accordingly.

  Extensions can implement different functionalities, for example a filter can be responsible for dropping silent
  audio packets when encountered VAD extension data in header extensions of a packet.
  """
  @type extension_t :: {Membrane.Child.name_t(), Membrane.ParentSpec.child_spec_t()}

  @ssrc_boundaries 2..(Bitwise.bsl(1, 32) - 1)

  @rtp_input_params [toilet_capacity: 500]

  def_options fmt_mapping: [
                spec: %{RTP.payload_type_t() => {RTP.encoding_name_t(), RTP.clock_rate_t()}},
                default: %{},
                description: "Mapping of the custom payload types ( > 95)"
              ],
              rtcp_receiver_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description: "Interval between sending subseqent RTCP receiver reports."
              ],
              rtcp_sender_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description: "Interval between sending subseqent RTCP sender reports."
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
  @spec generate_receiver_ssrc([RTP.ssrc_t()], [RTP.ssrc_t()]) :: RTP.ssrc_t()
  def generate_receiver_ssrc(local_ssrcs, remote_ssrcs) do
    fn -> Enum.random(@ssrc_boundaries) end
    |> Stream.repeatedly()
    |> Enum.find(&(&1 not in local_ssrcs and &1 not in remote_ssrcs))
  end

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      payloader: [
        spec: module() | nil,
        default: nil,
        description: """
        Payloader's module that should be used for a media stream flowing through the pad.

        If set to nil then the payloading process gets skipped.
        """
      ],
      rtp_extensions: [
        spec: [rtp_extension_options_t()],
        default: [],
        description: """
        List of RTP extension options. Currently supported is `:twcc` (sender) only.
        It will tag outgoing packets with transport-wide sequence numbers and estimate available bandwidth.
        For more information refer to `Membrane.RTP.TWCCSender` module documentation.
        """
      ]
    ]

  def_input_pad :rtp_input,
    demand_unit: :buffers,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    availability: :on_request

  def_output_pad :output,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      depayloader: [
        spec: module() | nil,
        default: nil,
        description: """
        Depayloader's module that should be used for an outgoing media stream flowing through the pad.

        If set to nil then the depayloading process gets skipped.
        """
      ],
      telemetry_label: [
        spec: Membrane.TelemetryMetrics.label(),
        default: [],
        description: "Label passed to Membrane.TelemetryMetrics functions"
      ],
      encoding: [
        spec: RTP.encoding_name_t() | nil,
        default: nil
      ],
      clock_rate: [
        spec: integer() | nil,
        default: nil,
        description: """
        Clock rate to use. If not provided, determined from `fmt_mapping` or defaults registered by proper plugins i.e.
        `Membrane.RTP.X.Plugin` where X is the name of codec corresponding to `encoding`.
        """
      ],
      rtp_extensions: [
        spec: [rtp_extension_options_t()],
        default: [],
        description: """
        List of RTP extension options. Currently `:vad` and `:twcc` (receiver) are supported.
        * `:vad` will turn on Voice Activity Detection mechanism firing appropriate notifications when needed.
        Should be set only for audio tracks. For more information refer to `Membrane.RTP.VAD` module documentation.
        * `:twcc` (receiver) will gather transport-wide information about received packets and generate feedbacks for sender.
        For more information refer to `Membrane.RTP.TWCCReceiver` module documentation.

        RTP extensions (except `:twcc`) are applied in the same order as passed to the pad options.
        """
      ],
      extensions: [
        spec: [extension_t()],
        default: [],
        description: """
        A list of general extensions that will be attached to the packets flow (added inside `Membrane.RTP.StreamReceiveBin`).
        In case of SRTP extensions are placed before the Decryptor. The order of provided elements is important
        as the extensions are applied in FIFO order.

        An extension can be responsible e.g. for dropping silent audio packets when encountered VAD extension data in the
        packet header.
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
      ],
      rtp_extension_mapping: [
        spec: rtp_extension_mapping_t(),
        default: nil,
        description: """
        Mapping from locally used `rtp_extension_name_t()` to integer identifiers expected by
        the receiver of a RTP stream.
        """
      ]
    ]

  def_output_pad :rtcp_receiver_output,
    demand_unit: :buffers,
    caps: {RemoteStream, type: :packetized, content_format: RTCP},
    availability: :on_request

  def_output_pad :rtcp_sender_output,
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
              rtcp_receiver_report_interval: nil,
              rtcp_sender_report_interval: nil,
              receiver_ssrc_generator: nil,
              rtcp_sender_report_data: %Session.SenderReport.Data{},
              secure?: false,
              srtp_policies: nil,
              receiver_srtp_policies: nil
  end

  @impl true
  def handle_init(options) do
    if options.secure? and not Code.ensure_loaded?(ExLibSRTP),
      do: raise("Optional dependency :ex_libsrtp is required when using secure option")

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
  def handle_pad_added(Pad.ref(:rtp_input, ref) = pad, ctx, %{secure?: secure?} = state) do
    rtcp_receiver_output = Pad.ref(:rtcp_receiver_output, ref)
    rtcp? = Map.has_key?(ctx.pads, rtcp_receiver_output)

    maybe_link_srtcp_decryptor =
      &to(
        &1,
        {:srtcp_decryptor, ref},
        struct(Membrane.SRTCP.Decryptor, %{policies: state.srtp_policies})
      )

    maybe_link_srtcp_encryptor =
      &to(
        &1,
        {:srtcp_encryptor, ref},
        struct(Membrane.SRTP.Encryptor, %{policies: state.receiver_srtp_policies})
      )

    links =
      [
        link_bin_input(pad)
        |> via_in(:input, @rtp_input_params)
        |> to({:rtp_parser, ref}, %RTP.Parser{secure?: secure?})
        |> via_in(Pad.ref(:input, ref))
        |> to(:ssrc_router)
      ] ++
        if rtcp? do
          [
            link({:rtp_parser, ref})
            |> via_out(:rtcp_output)
            |> then(if secure?, do: maybe_link_srtcp_decryptor, else: & &1)
            |> to({:rtcp_parser, ref}, RTCP.Parser)
            |> via_out(:receiver_report_output)
            |> then(if secure?, do: maybe_link_srtcp_encryptor, else: & &1)
            |> to_bin_output(rtcp_receiver_output),
            link({:rtcp_parser, ref})
            |> via_in(Pad.ref(:input, {:rtcp, ref}))
            |> to(:ssrc_router)
          ]
        else
          []
        end

    {{:ok, spec: %ParentSpec{links: links}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, ctx, state) do
    %{
      depayloader: depayloader,
      clock_rate: clock_rate,
      rtp_extensions: rtp_extensions,
      encoding: encoding,
      telemetry_label: telemetry_label,
      extensions: extensions
    } = ctx.pads[pad].options

    payload_type = Map.fetch!(state.ssrc_pt_mapping, ssrc)
    clock_rate = clock_rate || get_from_register!(:clock_rate, payload_type, state)

    {local_ssrc, state} = add_ssrc(ssrc, state)

    rtp_stream_name = {:stream_receive_bin, ssrc}

    new_children = %{
      rtp_stream_name => %RTP.StreamReceiveBin{
        clock_rate: clock_rate,
        depayloader: depayloader,
        extensions: extensions,
        local_ssrc: local_ssrc,
        remote_ssrc: ssrc,
        rtcp_report_interval: state.rtcp_receiver_report_interval,
        telemetry_label: telemetry_label,
        secure?: state.secure?,
        srtp_policies: state.srtp_policies
      }
    }

    {rtp_extensions, maybe_link_twcc_receiver, state} =
      maybe_handle_twcc_receiver(rtp_extensions, ssrc, ctx, state)

    ssrc_router_pad_options = [
      encoding: encoding,
      telemetry_label: telemetry_label
    ]

    router_link =
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc), options: ssrc_router_pad_options)
      |> then(maybe_link_twcc_receiver)
      |> to(rtp_stream_name)

    acc = {new_children, router_link}

    {new_children, router_link} =
      rtp_extensions
      |> Enum.reduce(acc, fn {extension_name, config}, {new_children, new_link} ->
        extension_id = {extension_name, ssrc}

        {
          Map.merge(new_children, %{extension_id => config}),
          new_link |> to(extension_id)
        }
      end)

    new_links = [router_link |> to_bin_output(pad)]

    {{:ok, spec: %ParentSpec{children: new_children, links: new_links}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_receiver_output, ref), ctx, state) do
    if Map.has_key?(ctx.children, {:rtp_parser, ref}) do
      raise "RTCP receiver output has to be linked before corresponding RTP input"
    end

    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_sender_output, ssrc), ctx, state) do
    if Map.has_key?(ctx.children, {:stream_send_bin, ssrc}) do
      raise "RTCP sender output has to be linked before corresponding input"
    end

    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(name, ssrc), ctx, state)
      when name in [:input, :rtp_output] do
    input_pad = Pad.ref(:input, ssrc)
    output_pad = Pad.ref(:rtp_output, ssrc)

    pads_present? = Enum.all?([input_pad, output_pad], &Map.has_key?(ctx.pads, &1))

    rtcp_sender_output = Pad.ref(:rtcp_sender_output, ssrc)
    rtcp? = Map.has_key?(ctx.pads, rtcp_sender_output)

    if not pads_present? or Map.has_key?(ctx.children, {:stream_send_bin, ssrc}) do
      {:ok, state}
    else
      %{payloader: payloader} = ctx.pads[input_pad].options

      %{clock_rate: clock_rate, rtp_extension_mapping: rtp_extension_mapping} =
        ctx.pads[output_pad].options

      payload_type = get_output_payload_type!(ctx, ssrc)
      clock_rate = clock_rate || get_from_register!(:clock_rate, payload_type, state)

      maybe_link_encryptor =
        &to(&1, {:srtp_encryptor, ssrc}, struct(SRTP.Encryptor, %{policies: state.srtp_policies}))

      %{rtp_extensions: rtp_extensions} = ctx.pads[input_pad].options

      {_rtp_extensions, maybe_link_twcc_sender} =
        maybe_handle_twcc_sender(rtp_extensions, ssrc, ctx)

      links = [
        link_bin_input(input_pad)
        |> then(maybe_link_twcc_sender)
        |> to({:stream_send_bin, ssrc}, %RTP.StreamSendBin{
          ssrc: ssrc,
          payload_type: payload_type,
          payloader: payloader,
          clock_rate: clock_rate,
          rtcp_report_interval: state.rtcp_sender_report_interval,
          rtp_extension_mapping: rtp_extension_mapping || %{}
        })
        |> then(if state.secure?, do: maybe_link_encryptor, else: & &1)
        |> to_bin_output(output_pad)
      ]

      # if RTCP is present create all set of input and output pads for RTCP flow
      rtcp_links =
        if rtcp? do
          link_srtcp_encryptor =
            &to(
              &1,
              {:srtcp_sender_encryptor, ssrc},
              struct(SRTP.Encryptor, %{
                policies: state.srtp_policies
              })
            )

          [
            link({:stream_send_bin, ssrc})
            |> via_out(:rtcp_output)
            |> then(if state.secure?, do: link_srtcp_encryptor, else: & &1)
            |> to_bin_output(rtcp_sender_output),
            link(:ssrc_router)
            |> via_out(Pad.ref(:output, ssrc))
            |> via_in(:rtcp_input)
            |> to({:stream_send_bin, ssrc})
          ]
        else
          []
        end

      spec = %ParentSpec{links: links ++ rtcp_links}
      state = %{state | senders_ssrcs: MapSet.put(state.senders_ssrcs, ssrc)}

      {{:ok, spec: spec}, state}
    end
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtp_input, ref), ctx, state) do
    children =
      [
        :rtp_parser,
        :rtcp_parser,
        :srtcp_decryptor,
        :srtcp_encryptor
      ]
      |> Enum.map(&{&1, ref})
      |> Enum.filter(&Map.has_key?(ctx.children, &1))

    {{:ok, remove_child: children}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, ssrc), ctx, state) do
    # TODO: parent may not know when to unlink, we need to timout SSRCs and notify about that and BYE packets over RTCP
    state = %{state | ssrcs: Map.delete(state.ssrcs, ssrc)}
    stream_receive_bin = Map.get(ctx.children, {:stream_receive_bin, ssrc})

    if stream_receive_bin != nil and !stream_receive_bin.terminating? do
      {{:ok, remove_child: {:stream_receive_bin, ssrc}}, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_pad_removed(Pad.ref(name, ssrc), ctx, state)
      when name in [:input, :rtp_output] do
    children =
      for {child_name, child} <-
            Map.take(ctx.children, [{:stream_send_bin, ssrc}, {:srtp_encryptor, ssrc}]),
          !child.terminating?,
          into: [] do
        child_name
      end

    {{:ok, remove_child: children}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(name, _ref), _ctx, state)
      when name in [:rtcp_receiver_output, :rtcp_sender_output] do
    {:ok, state}
  end

  @impl true
  def handle_notification(
        {:new_rtp_stream, ssrc, payload_type, extensions},
        :ssrc_router,
        _ctx,
        state
      ) do
    state = put_in(state.ssrc_pt_mapping[ssrc], payload_type)
    {{:ok, notify: {:new_rtp_stream, ssrc, payload_type, extensions}}, state}
  end

  @impl true
  def handle_notification({:vad, _val} = msg, _from, _ctx, state) do
    {{:ok, notify: msg}, state}
  end

  @impl true
  def handle_notification({:bandwidth_estimation, _val} = msg, :twcc_sender, _ctx, state) do
    {{:ok, notify: msg}, state}
  end

  @impl true
  def handle_notification({:twcc_feedback, _feedback} = msg, _rtcp_parser, _ctx, state) do
    {{:ok, forward: {:twcc_sender, msg}}, state}
  end

  defp add_ssrc(remote_ssrc, state) do
    %{ssrcs: ssrcs, receiver_ssrc_generator: generator} = state
    local_ssrc = generator.([remote_ssrc | Map.keys(ssrcs)], Map.values(ssrcs))
    {local_ssrc, put_in(state, [:ssrcs, remote_ssrc], local_ssrc)}
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

  defp get_output_payload_type!(ctx, ssrc) do
    pad = Pad.ref(:rtp_output, ssrc)
    %{payload_type: pt, encoding: encoding} = ctx.pads[pad].options

    unless pt || encoding do
      raise "Neither payload_type nor encoding specified for #{inspect(pad)})"
    end

    pt || PayloadFormat.get(encoding).payload_type ||
      raise "Cannot find default RTP payload type for encoding #{encoding}"
  end

  defp maybe_handle_twcc_receiver(rtp_extensions, pad_ssrc, ctx, state) do
    # Workaround: as TWCC is a transport-wide extension, there should exist only one TWCC receiver
    # child that handles packets from all incoming streams that have declared support for it.
    {maybe_twcc, rtp_extensions} = Keyword.pop(rtp_extensions, :twcc)

    should_link? = maybe_twcc != nil
    should_create_child? = not Map.has_key?(ctx.children, :twcc_receiver)

    {maybe_twcc_ssrc, state} =
      if should_link? and should_create_child? do
        add_ssrc(nil, state)
      else
        {nil, state}
      end

    maybe_link_twcc =
      if should_link? do
        fn link_builder ->
          link_builder
          |> via_in(Pad.ref(:input, pad_ssrc))
          |> then(fn link ->
            if should_create_child? do
              to(link, :twcc_receiver, %{maybe_twcc | feedback_sender_ssrc: maybe_twcc_ssrc})
            else
              to(link, :twcc_receiver)
            end
          end)
          |> via_out(Pad.ref(:output, pad_ssrc))
        end
      else
        & &1
      end

    {rtp_extensions, maybe_link_twcc, state}
  end

  defp maybe_handle_twcc_sender(rtp_extensions, pad_ssrc, ctx) do
    # Workaround: as TWCC is a transport-wide extension, there should exist only one TWCC sender
    # child that handles packets for all outgoing streams.
    {maybe_twcc, rtp_extensions} = Keyword.pop(rtp_extensions, :twcc)

    should_link? = maybe_twcc != nil

    should_create_child? = not Map.has_key?(ctx.children, :twcc_sender)

    maybe_link_twcc =
      if should_link? do
        fn link_builder ->
          link_builder
          |> via_in(Pad.ref(:input, pad_ssrc))
          |> then(fn link ->
            if should_create_child? do
              to(link, :twcc_sender, maybe_twcc)
            else
              to(link, :twcc_sender)
            end
          end)
          |> via_out(Pad.ref(:output, pad_ssrc))
        end
      else
        & &1
      end

    {rtp_extensions, maybe_link_twcc}
  end
end
