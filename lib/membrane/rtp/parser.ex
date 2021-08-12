defmodule Membrane.RTP.Parser do
  @moduledoc """
  Identifies RTP/RTCP packets, then tries to parse RTP packet (parsing header and preparing payload)
  and forwards RTCP packet to `:rtcp_output` pad unchanged.

  ## Encrypted packets
  In case of SRTP/SRTCP the parser tries to parse just the header of the RTP packet as the packet's payload
  is encrypted and must be passed as a whole to the decryptor. The whole packet remains unchanged but
  the parsed header gets  attached to `Membrane.Buffer`'s metadata.

  SRTP is treated the same as RTCP and all packets gets forwarded to `:rtcp_output` pad.

  ## Parsed packets
  In both cases, encrypted and unencryptd, parsed header is put into the metadata field in `Membrane.Buffer` under `:rtp` key.
  with the following metadata `:timestamp`, `:sequence_number`, `:ssrc`, `:payload_type`,
  `:marker`, `:extension`. See `Membrane.RTP.Header` for their meaning and specifications.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.{RTCPEvent, RTP, RemoteStream}

  require Membrane.Logger

  @metadata_fields [
    :timestamp,
    :sequence_number,
    :ssrc,
    :csrcs,
    :payload_type,
    :marker,
    :extension
  ]

  def_options secure?: [
                type: :boolean,
                default: false,
                description: """
                Specifies whether Parser should expect packets that are encrypted or not.
                Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
                """
              ]

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    demand_unit: :buffers

  def_output_pad :output, caps: RTP

  def_output_pad :rtcp_output, mode: :push, caps: :any, availability: :on_request

  @impl true
  def handle_init(opts) do
    {:ok, %{rtcp_output_pad: nil, secure?: opts.secure?}}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {{:ok, caps: {:output, %RTP{}}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, _ctx, state) do
    {:ok, %{state | rtcp_output_pad: pad}}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata} = buffer, _ctx, state) do
    with :rtp <- RTP.Packet.identify(payload),
         {:ok,
          %{packet: packet, has_padding?: has_padding?, total_header_size: total_header_size}} <-
           RTP.Packet.parse(payload, not state.secure?) do
      metadata =
        Map.merge(metadata, %{has_padding?: has_padding?, total_header_size: total_header_size})

      actions = process_packet(packet, metadata)
      {{:ok, actions}, state}
    else
      :rtcp ->
        case state.rtcp_output_pad do
          nil ->
            {:ok, state}

          pad ->
            {{:ok, buffer: {pad, buffer}}, state}
        end

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't parse rtp packet:
        #{inspect(payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)

        {:ok, state}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_event(:output, %RTCPEvent{} = event, _ctx, state) do
    case state.rtcp_output_pad do
      nil ->
        {:ok, state}

      pad ->
        {{:ok, event: {pad, event}}, state}
    end
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp process_packet(%RTP.Packet{} = rtp, metadata) do
    extracted = Map.take(rtp.header, @metadata_fields)
    metadata = Map.put(metadata, :rtp, extracted)
    [buffer: {:output, %Buffer{payload: rtp.payload, metadata: metadata}}]
  end
end
