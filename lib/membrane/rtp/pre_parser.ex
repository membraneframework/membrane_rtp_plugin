defmodule Membrane.RTP.PreParser do
  @moduledoc """
  Element that should be used for packet pre-parsing to further decide if it should be discarded or passed to the Decryptor.
  By pre-parsing we mean identifying the packet based on unencrypted header and parsing as many available information as possible.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.RTCP
  alias Membrane.RTP

  require Membrane.Logger

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  @impl true
  def handle_init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload} = buffer, _ctx, state) do
    header_parser =
      case RTP.Packet.identify(payload) do
        :rtp -> &parse_rtp_header/1
        :rtcp -> &parse_rtcp_header/1
      end

    case header_parser.(payload) do
      {:ok, header} ->
        {{:ok, buffer: {:output, %Buffer{payload: payload, metadata: header}}, redemand: :output},
         state}

      {:error, :malformed_packet} ->
        Membrane.Logger.warn("""
        Couldn't parse packet:
        #{inspect(payload, limit: :infinity)}
        Reason: malformed header. Ignoring packet.
        """)

        {:ok, state}
    end
  end

  defp parse_rtp_header(
         <<version::2, has_padding::1, has_extension::1, csrcs_cnt::4, marker::1, payload_type::7,
           sequence_number::16, timestamp::32, ssrc::32, csrcs::binary-size(csrcs_cnt)-unit(32),
           extension_profile_specific::binary-size(has_extension)-unit(16),
           extension_data_len::size(has_extension)-unit(16),
           extension_data::binary-size(extension_data_len)-unit(32), _rest::binary>>
       ) do
    extension =
      if extension_profile_specific != <<>> do
        %RTP.Header.Extension{profile_specific: extension_profile_specific, data: extension_data}
      else
        nil
      end

    header = %RTP.Header{
      version: version,
      marker: marker == 1,
      ssrc: ssrc,
      sequence_number: sequence_number,
      payload_type: payload_type,
      timestamp: timestamp,
      csrcs: for(<<csrc::32 <- csrcs>>, do: csrc),
      extension: extension
    }

    {:ok, header}
  end

  defp parse_rtp_header(_packet), do: {:error, :malformed_packet}

  defp parse_rtcp_header(<<header::binary-size(1)-unit(32), _rest::binary>>) do
    case RTCP.Header.parse(header) do
      {:ok, %{header: header}} ->
        {:ok, header}

      :error ->
        {:error, :malformed_packet}
    end
  end

  defp parse_rtcp_header(_packet), do: {:error, :malformed_packet}
end
