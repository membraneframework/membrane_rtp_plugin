defmodule Membrane.RTCP.Fixtures do
  @moduledoc false

  @external_resource "test/fixtures/rtcp/rtcp_packet.hex"
  @sample_rtcp_packet File.read!(@external_resource)

  @external_resource "test/fixtures/rtcp/packets.hex"
  @sample_rtcp_communication File.read!("test/fixtures/rtcp/packets.hex")

  @spec sample_packet() :: binary()
  def sample_packet, do: hex_to_bin(@sample_rtcp_packet)

  def packet_list() do
    @sample_rtcp_communication
    |> String.split()
    |> Enum.map(&hex_to_bin/1)
  end

  def packet_list_contents() do
    ssrc = 0x62DBEFD0
    cname = "user2465330910@host-447eb16f"
    tool = "GStreamer"

    # Decoded with Wireshark
    [
      %{
        ssrc: ssrc,
        sender_packets: 66,
        sender_octets: 11215,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        sender_packets: 300,
        sender_octets: 54729,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        sender_packets: 550,
        sender_octets: 101_879,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        sender_packets: 712,
        sender_octets: 132_620,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        sender_packets: 868,
        sender_octets: 162_252,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        sender_packets: 984,
        sender_octets: 184_346,
        cname: cname,
        tool: tool
      }
    ]
  end

  def hex_to_bin(hex) do
    hex
    |> String.trim_trailing()
    |> String.upcase()
    |> Base.decode16()
    |> case do
      {:ok, packet} -> packet
    end
  end
end
