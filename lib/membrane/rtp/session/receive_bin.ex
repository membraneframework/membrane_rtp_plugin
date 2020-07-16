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

  alias Membrane.ParentSpec
  alias Membrane.RTP
  alias Membrane.RTP.Packet.PayloadType

  @bin_input_buffer_params [warn_size: 250, fail_size: 500]

  @known_depayloaders %{
    H264: Membrane.RTP.H264.Depayloader,
    MPA: Membrane.RTP.MPEGAudio.Depayloader
  }

  def_options fmt_mapping: [
                spec: %{integer => RTP.payload_type_t()},
                default: %{},
                description: "Mapping of the custom payload types (for fmt > 95)"
              ],
              custom_depayloaders: [
                spec: %{RTP.payload_type_t() => module()},
                default: %{},
                description: "Mapping from a payload type to a custom depayloader module"
              ]

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request
  def_input_pad :rtcp_input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, demand_unit: :buffers, availability: :on_request

  defmodule State do
    @moduledoc false

    defstruct fmt_mapping: %{},
              ssrc_pt_mapping: %{},
              depayloaders: nil
  end

  @impl true
  def handle_init(%{fmt_mapping: fmt_map, custom_depayloaders: custom_depayloaders}) do
    children = [ssrc_router: RTP.SSRCRouter]
    links = []

    spec = %ParentSpec{children: children, links: links}

    depayloaders = Map.merge(@known_depayloaders, custom_depayloaders)
    {{:ok, spec: spec}, %State{fmt_mapping: fmt_map, depayloaders: depayloaders}}
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
  def handle_pad_added(
        Pad.ref(:output, ssrc) = pad,
        _ctx,
        %State{ssrc_pt_mapping: ssrc_pt_mapping} = state
      ) do
    payload_type = ssrc_pt_mapping |> Map.get(ssrc)

    depayloader =
      case state.depayloaders[payload_type] do
        nil -> raise "Cannot find depayloader for payload type #{payload_type}"
        depayloader -> depayloader
      end

    rtp_stream_name = {:rtp_stream_bin, ssrc}

    new_children = [
      {rtp_stream_name, %RTP.StreamReceiveBin{depayloader: depayloader, ssrc: ssrc}}
    ]

    new_links = [
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc))
      |> to(rtp_stream_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, ref), _ctx, state) do
    {{:ok, remove_child: {:rtp_parser, ref}}, state}
  end

  def handle_pad_removed(Pad.ref(:rtcp_input, ref), _ctx, state) do
    {{:ok, remove_child: {:rtcp_parser, ref}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, ssrc), _ctx, state) do
    # TODO: parent may not know when to unlink, we need to timout SSRCs and notify about that and BYE packets over RTCP
    {{:ok, remove_child: {:rtp_stream_bin, ssrc}}, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, pt_num}, :ssrc_router, state) do
    %State{ssrc_pt_mapping: ssrc_pt_mapping, fmt_mapping: fmt_map} = state

    pt_name =
      case PayloadType.get_encoding_name(pt_num) do
        :dynamic -> fmt_map[pt_num]
        pt -> pt
      end

    if pt_name == nil do
      raise "Unknown RTP payload type #{pt_num}"
    end

    new_ssrc_pt_mapping = ssrc_pt_mapping |> Map.put(ssrc, pt_name)

    {{:ok, notify: {:new_rtp_stream, ssrc, pt_name}},
     %{state | ssrc_pt_mapping: new_ssrc_pt_mapping}}
  end

  @impl true
  def handle_notification({:received_rtcp, _rtcp}, {:rtcp_parser, _ref}, state) do
    # TODO: handle RTCP reports properly
    {:ok, state}
  end
end
