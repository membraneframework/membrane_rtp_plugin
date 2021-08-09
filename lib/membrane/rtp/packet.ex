defmodule Membrane.RTP.Packet do
  @moduledoc """
  Defines a struct describing an RTP packet and a way to parse and serialize it.
  Based on [RFC3550](https://tools.ietf.org/html/rfc3550#page-13)
  """

  alias Membrane.RTP.{Header, Utils}

  @type t :: %__MODULE__{
          header: Header.t(),
          payload: binary()
        }

  @enforce_keys [:header, :payload]
  defstruct @enforce_keys

  @spec identify(binary()) :: :rtp | :rtcp
  def identify(<<_first_byte, _marker::1, payload_type::7, _rest::binary>>)
      when payload_type in 64..95,
      do: :rtcp

  def identify(_packet), do: :rtp

  @spec serialize(t, align_to: pos_integer()) :: binary
  def serialize(%__MODULE__{} = packet, [align_to: align_to] \\ [align_to: 1]) do
    %__MODULE__{header: header, payload: payload} = packet
    %Header{version: 2} = header
    has_padding = 0
    has_extension = if header.extension, do: 1, else: 0
    marker = if header.marker, do: 1, else: 0
    csrcs = Enum.map_join(header.csrcs, &<<&1::32>>)

    serialized =
      <<header.version::2, has_padding::1, has_extension::1, length(header.csrcs)::4, marker::1,
        header.payload_type::7, header.sequence_number::16, header.timestamp::32, header.ssrc::32,
        csrcs::binary, serialize_header_extension(header.extension)::binary, payload::binary>>

    case Utils.align(serialized, align_to) do
      {serialized, 0} ->
        serialized

      {serialized, _padding} ->
        <<pre::2, _has_padding::1, post::bitstring>> = serialized
        <<pre::2, 1::1, post::bitstring>>
    end
  end

  defp serialize_header_extension(nil) do
    <<>>
  end

  defp serialize_header_extension(%Header.Extension{data: data} = extension)
       when byte_size(data) |> rem(4) == 0 do
    <<extension.profile_specific::bitstring, byte_size(data) |> div(4)::16, data::binary>>
  end

  @spec parse(binary(), boolean()) :: {:ok, t()} | {:error, :wrong_version | :malformed_packet}
  def parse(packet, parse_payload?)

  def parse(<<version::2, _::bitstring>>, _parse_payload?) when version != 2,
    do: {:error, :wrong_version}

  def parse(
        <<version::2, has_padding::1, has_extension::1, csrcs_cnt::4, marker::1, payload_type::7,
          sequence_number::16, timestamp::32, ssrc::32, csrcs::binary-size(csrcs_cnt)-unit(32),
          rest::binary>> = unmodified_payload,
        parse_payload?
      ) do
    with {:ok, {extension, header_extension_size, payload}} <-
           parse_header_extension(rest, has_extension == 1, parse_payload?),
         {:ok, {payload, _padding}} =
           Utils.strip_padding(payload, parse_payload? and has_padding == 1) do
      header = %Header{
        version: version,
        marker: marker == 1,
        ssrc: ssrc,
        sequence_number: sequence_number,
        payload_type: payload_type,
        timestamp: timestamp,
        csrcs: for(<<csrc::32 <- csrcs>>, do: csrc),
        extension: extension,
        has_padding?: has_padding == 1,
        total_header_size: 32 + 32 + 32 + 32 * csrcs_cnt + header_extension_size
      }

      {:ok,
       %__MODULE__{
         header: header,
         payload: if(parse_payload?, do: payload, else: unmodified_payload)
       }}
    else
      :error -> {:error, :malformed_packet}
    end
  end

  def parse(_binary, _parse_payload?), do: {:error, :malformed_packet}

  defp parse_header_extension(binary, header_present?, parse_payload?)
  defp parse_header_extension(binary, false, _parse_payload?), do: {:ok, {nil, 0, binary}}

  defp parse_header_extension(
         <<profile_specific::binary-size(2), data_len::16, data::binary-size(data_len)-unit(32),
           rest::binary>> = unmodified_payload,
         true,
         parse_payload?
       ) do
    extension = %Header.Extension{profile_specific: profile_specific, data: data}

    {:ok, {extension, 32 + data_len * 32, if(parse_payload?, do: rest, else: unmodified_payload)}}
  end

  defp parse_header_extension(_binary, true, _parse_payload?), do: :error
end
