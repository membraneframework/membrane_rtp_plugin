defmodule Membrane.RTP.Parser do
  @moduledoc """
  Parses RTP packets.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.{RTP, Stream}
  alias Membrane.RTP.{Header, Packet}

  @metadata_fields [:timestamp, :sequence_number, :ssrc, :payload_type]

  def_input_pad :input,
    caps: {Stream, type: :packet_stream, content: one_of([nil, RTP])},
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
  def handle_process(:input, %Buffer{payload: buffer_payload} = buffer, _ctx, state) do
    with {:ok, %Packet{} = packet} <- Packet.parse(buffer_payload) do
      {{:ok, buffer: {:output, build_buffer(buffer, packet)}}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @spec build_buffer(Buffer.t(), Packet.t()) :: Buffer.t()
  defp build_buffer(
         %Buffer{metadata: metadata} = original_buffer,
         %Packet{payload: payload} = packet
       ) do
    updated_metadata = build_metadata(packet, metadata)
    %Buffer{original_buffer | payload: payload, metadata: updated_metadata}
  end

  @spec build_metadata(Packet.t(), map()) :: map()
  defp build_metadata(%Packet{header: %Header{} = header}, metadata) do
    extracted = Map.take(header, @metadata_fields)
    Map.put(metadata, :rtp, extracted)
  end
end
