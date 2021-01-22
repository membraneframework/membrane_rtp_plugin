defmodule Membrane.RTP.Parser do
  @moduledoc """
  Parses RTP packets.

  Outputs each packet payload as a separate `Membrane.Buffer`.
  Attaches the following metadata under `:rtp` key: `:timestamp`, `:sequence_number`,
  `:ssrc`, `:payload_type`, `:marker`, `:extension`. See `Membrane.RTP.Header` for
  their meaning and specifications.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.{RTCP, RTP, RemoteStream}

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

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    demand_unit: :buffers

  def_output_pad :output, caps: RTP

  @impl true
  def handle_init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {{:ok, caps: {:output, %RTP{}}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    %Buffer{payload: payload} = buffer
    packet_type = RTP.Packet.identify(payload)

    case packet_type do
      :rtp -> RTP.Packet.parse(payload)
      :rtcp -> RTCP.CompoundPacket.parse(payload)
    end
    |> case do
      {:ok, packet} ->
        buffers = process_packet(packet, buffer.metadata)
        {{:ok, buffer: {:output, buffers}}, state}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't parse #{packet_type} packet:
        #{inspect(payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  defp process_packet(%RTP.Packet{} = packet, metadata) do
    extracted = Map.take(packet.header, @metadata_fields)
    metadata = Map.put(metadata, :rtp, extracted)
    %Buffer{payload: packet.payload, metadata: metadata}
  end

  defp process_packet(%RTCP.CompoundPacket{} = packet, _metadata) do
    IO.inspect(packet)
    []
  end
end
