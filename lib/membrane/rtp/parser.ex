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

  require Membrane.Logger
  alias Membrane.Buffer
  alias Membrane.{RemoteStream, RTCP, RTCPEvent, RTP}
  alias Membrane.SRTP.Decryptor2
  alias Membrane.SRTP

  @metadata_fields [
    :timestamp,
    :sequence_number,
    :ssrc,
    :csrcs,
    :payload_type,
    :marker,
    :extensions
  ]

  def_options secure?: [
                type: :boolean,
                default: false,
                description: """
                Specifies whether Parser should expect packets that are encrypted or not.
                Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
                """
              ],
              policies: [
                spec: [ExLibSRTP.Policy.t()],
                default: [],
                description: """
                List of SRTP policies to use for decrypting packets.
                See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ]

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP, RTCP])},
    demand_mode: :auto

  def_output_pad :output, caps: RTP, demand_mode: :auto

  def_output_pad :rtcp_output,
    mode: :push,
    caps: {RemoteStream, content_format: RTCP, type: :packetized},
    availability: :on_request

  @impl true
  def handle_init(opts) do
    {:ok, %{rtcp_output_pad: nil, secure?: opts.secure?, policies: opts.policies, decryptor: nil}}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {{:ok, caps: {:output, %RTP{}}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, %{playback_state: :playing}, state) do
    caps = {:caps, {pad, %RemoteStream{content_format: RTCP, type: :packetized}}}
    {{:ok, [caps]}, %{state | rtcp_output_pad: pad}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, _ctx, state) do
    {:ok, %{state | rtcp_output_pad: pad}}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, %{secure?: true} = state) do
    decryptor = Decryptor2.new(state.policies)
    {:ok, %{state | decryptor: decryptor}}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, %{rtcp_output_pad: pad} = state) when pad != nil do
    caps = {:caps, {pad, %RemoteStream{content_format: RTCP, type: :packetized}}}
    {{:ok, [caps]}, state}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state), do: super(ctx, state)

  @impl true
  def handle_process(:input, %Buffer{payload: payload} = buffer, _ctx, state) do
    case RTP.Packet.identify(payload) do
      :rtp -> handle_rtp_packet(buffer, state)
      :rtcp -> handle_rtcp_packet(buffer, state)
    end
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
  def handle_event(_pad, %SRTP.KeyingMaterialEvent{} = event, _ctx, %{secure?: true} = state) do
    decryptor = Decryptor2.configure(state.decryptor, event)
    state = %{state | decryptor: decryptor}
    {:ok, state}
  end

  @impl true
  def handle_event(_pad, %SRTP.KeyingMaterialEvent{}, _ctx, %{secure?: false} = state) do
    Membrane.Logger.warn(
      "Got SRTP.KeyingMaterialEvent but RTP was not configured with the secure option. Ignoring."
    )

    {:ok, state}
  end

  @impl true
  def handle_event(_pad, %SRTP.KeyingMaterialEvent{}, _ctx, state) do
    Membrane.Logger.warn("Got unexpected SRTP.KeyingMaterialEvent. Ignoring.")
    {:ok, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp handle_rtp_packet(%Buffer{payload: payload, metadata: metadata}, state) do
    payload =
      if state.secure? do
        case Decryptor2.unprotect(state.decryptor, payload) do
          {:ok, payload} ->
            payload

          {:error, reason} when reason in [:replay_fail, :replay_old] ->
            Membrane.Logger.debug("""
            Couldn't unprotect srtp packet:
            #{inspect(payload, limit: :infinity)}
            Reason: #{inspect(reason)}. Ignoring packet.
            """)

            {:ok, state}

          {:error, reason} ->
            raise "Couldn't unprotect SRTP packet due to #{inspect(reason)}"
        end
      end

    case RTP.Packet.parse(payload) do
      {:ok, %{packet: packet, padding_size: padding_size}} ->
        %RTP.Packet{payload: payload, header: header} = packet

        rtp =
          header
          |> Map.take(@metadata_fields)
          |> Map.merge(%{padding_size: padding_size})

        metadata = Map.put(metadata, :rtp, rtp)
        {{:ok, buffer: {:output, %Buffer{payload: payload, metadata: metadata}}}, state}

      {:error, reason} ->
        Membrane.Logger.debug("""
        Couldn't parse rtp packet:
        #{inspect(payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)

        {:ok, state}
    end
  end

  defp handle_rtcp_packet(buffer, state) do
    case state.rtcp_output_pad do
      nil -> {:ok, state}
      pad -> {{:ok, buffer: {pad, buffer}}, state}
    end
  end
end
