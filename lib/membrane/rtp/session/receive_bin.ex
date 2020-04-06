defmodule Membrane.RTP.Session.ReceiveBin do
  # TODO: Either rename and add sending support or wrap in a bin handling both receiving and sending
  @moduledoc """
  A bin consuming one or more RTP streams on each input and outputting a stream from one ssrc on each output

  Every stream is parsed and then (based on ssrc field) an
  appropriate rtp session is initiated. It notifies its parent about each new
  stream with a notification of the format `{:new_rtp_stream, ssrc, payload_type}`.
  Parent should then connect to RTP bin dynamic output pad instance that will
  have an id == `ssrc`.
  """
  use Membrane.Bin

  alias Membrane.ParentSpec
  alias Membrane.RTP
  alias Membrane.RTP.Packet.PayloadType

  @bin_input_buffer_params [warn_size: 250, fail_size: 500]

  @known_depayloaders %{
    # TODO: Rename the elements
    h264: Membrane.RTP.H264.Depayloader,
    mpa: Membrane.RTP.MPEGAudio.Depayloader
  }

  def_options fmt_mapping: [
                spec: %{integer => RTP.payload_type()},
                default: %{},
                description: "Mapping of the custom payload types (for fmt > 95)"
              ],
              custom_depayloaders: [
                spec: %{RTP.payload_type() => module()},
                default: %{},
                description: "Mapping from a payload type to a custom depayloader module"
              ]

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, demand_unit: :buffers, availability: :on_request

  defmodule State do
    @moduledoc false

    defstruct fmt_mapping: %{},
              ssrc_pt_mapping: %{},
              depayloaders: nil,
              children_by_pads: %{}
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
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    parser_ref = {:parser, make_ref()}

    children = [{parser_ref, RTP.Parser}]

    links = [
      link_bin_input(pad)
      |> via_in(:input, buffer: @bin_input_buffer_params)
      |> to(parser_ref)
      |> to(:ssrc_router)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    children_by_pads = state.children_by_pads |> Map.put(pad, parser_ref)

    state = %{state | children_by_pads: children_by_pads}

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

    rtp_session_name = {:rtp_session, make_ref()}
    new_children = [{rtp_session_name, %RTP.Session.Source{depayloader: depayloader}}]

    new_links = [
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc))
      |> to(rtp_session_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    new_children_by_pads = state.children_by_pads |> Map.put(pad, rtp_session_name)

    {{:ok, spec: new_spec}, %State{state | children_by_pads: new_children_by_pads}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state) do
    {parser_to_remove, new_children_by_pads} = state.children_by_pads |> Map.pop(pad)

    {{:ok, remove_child: parser_to_remove},
     %State{state | children_by_pads: new_children_by_pads}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, _ssrc) = pad, _ctx, state) do
    {session_to_remove, new_children_by_pads} = state.children_by_pads |> Map.pop(pad)

    {{:ok, remove_child: session_to_remove},
     %State{state | children_by_pads: new_children_by_pads}}
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
end
