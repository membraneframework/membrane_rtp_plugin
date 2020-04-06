defmodule Membrane.RTCP.SdesPacket do
  @moduledoc """
  Parses Source Description (SDES) RTCP Packets defined in
  [RFC3550](https://tools.ietf.org/html/rfc3550#section-6.5)
  """
  @sdes_types %{
    1 => :cname,
    2 => :name,
    3 => :email,
    4 => :phone,
    5 => :loc,
    6 => :tool,
    7 => :note,
    8 => :priv
  }

  # TODO add error packet malformed returns
  defstruct chunks: []
  @type t() :: %__MODULE__{chunks: Keyword.t(tuple())}

  def parse(packet), do: {:ok, %__MODULE__{chunks: parse_chunks(packet, [])}}

  defp parse_chunks(<<>>, acc), do: acc

  defp parse_chunks(<<ssrc::32, rest::binary>>, acc) do
    {items, rest} = parse_items(rest)
    items = Enum.map(items, fn {name, value} -> {name, ssrc, value} end)
    parse_chunks(rest, items ++ acc)
  end

  defp parse_items(items), do: parse_items(items, [])

  defp parse_items(<<0::8, rest::binary>>, acc) do
    # skip padding
    to_skip = rest |> bit_size |> rem(32)
    <<_skipped::size(to_skip), next_items::binary>> = rest
    {acc, next_items}
  end

  defp parse_items(<<si_type::8, _::binary>>, _acc) when si_type not in 0..8,
    do: {:error, :unknown_si_type}

  defp parse_items(<<si_type::8, length::8, value::binary-size(length), rest::binary>>, acc) do
    # TODO better handling of PRIV items (prefix length, prefix, value)
    item = {@sdes_types[si_type], value}
    parse_items(rest, [item | acc])
  end
end
