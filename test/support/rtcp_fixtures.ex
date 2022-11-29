defmodule Membrane.RTCP.Fixtures do
  @moduledoc false

  @sample_rtcp_packet File.read!("test/fixtures/rtcp/single_packet.hex")
  @sample_rtcp_communication File.read!("test/fixtures/rtcp/packets.hex")
  @with_unknown_pt File.read!("test/fixtures/rtcp/with_unknown_pt.hex")
  @malformed_packet File.read!("test/fixtures/rtcp/malformed.hex")
  @twcc_feedbacks File.read!("test/fixtures/rtcp/twcc_feedbacks.hex")
  @twcc_malformed_feedbacks File.read!("test/fixtures/rtcp/twcc_malformed_feedbacks.hex")

  @spec sample_packet_binary() :: binary()
  def sample_packet_binary, do: hex_to_bin(@sample_rtcp_packet)

  @spec malformed_packet_binary() :: binary()
  def malformed_packet_binary, do: hex_to_bin(@malformed_packet)

  @spec with_unknown_packet_type() :: binary()
  def with_unknown_packet_type, do: hex_to_bin(@with_unknown_pt)

  @spec packet_list() :: [binary()]
  def packet_list() do
    @sample_rtcp_communication
    |> String.split()
    |> Enum.map(&hex_to_bin/1)
  end

  @doc """
  Returns a real, compound RTCP packet from browser containing SenderReport, Sdes & AFB with REMB
  """
  @spec compound_sr_sdes_remb() :: binary()
  def compound_sr_sdes_remb() do
    <<128, 200, 0, 6, 120, 61, 239, 185, 230, 110, 197, 157, 82, 42, 144, 205, 172, 85, 146, 216,
      0, 0, 3, 121, 0, 14, 109, 134, 129, 202, 0, 6, 120, 61, 239, 185, 1, 16, 116, 79, 97, 68,
      55, 57, 102, 72, 120, 105, 119, 102, 110, 56, 120, 85, 0, 0, 143, 206, 0, 5, 120, 61, 239,
      185, 0, 0, 0, 0, 82, 69, 77, 66, 1, 15, 36, 147, 224, 97, 78, 29>>
  end

  @spec pli_packet() :: binary()
  def pli_packet() do
    <<0x81, 0xCE, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x41, 0x6F, 0xB1, 0x0D>>
  end

  @spec pli_contents() :: binary()
  def pli_contents() do
    %{
      origin_ssrc: 1,
      target_ssrc: 0x416FB10D
    }
  end

  @spec twcc_feedbacks() :: [binary()]
  def twcc_feedbacks() do
    @twcc_feedbacks
    |> String.split()
    |> Enum.map(&hex_to_bin/1)
  end

  @spec twcc_malformed_feedbacks() :: [binary()]
  def twcc_malformed_feedbacks() do
    @twcc_malformed_feedbacks
    |> String.split()
    |> Enum.map(&hex_to_bin/1)
  end

  @spec packet_list_contents() :: [map()]
  def packet_list_contents() do
    ssrc = 0x62DBEFD0
    cname = "user2465330910@host-447eb16f"
    tool = "GStreamer"

    # Decoded with Wireshark
    [
      %{
        ssrc: ssrc,
        rtp_timestamp: 309_557_624,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:23.349522Z", 999),
        sender_packets: 66,
        sender_octets: 11_215,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 309_797_521,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:28.789375Z", 999),
        sender_packets: 300,
        sender_octets: 54_729,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_053_061,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:34.583922Z", 999),
        sender_packets: 550,
        sender_octets: 101_879,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_219_178,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:38.350761Z", 999),
        sender_packets: 712,
        sender_octets: 132_620,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_379_064,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:41.976296Z", 999),
        sender_packets: 868,
        sender_octets: 162_252,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_497_973,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:44.672643Z", 999),
        sender_packets: 984,
        sender_octets: 184_346,
        cname: cname,
        tool: tool
      }
    ]
  end

  @spec twcc_feedbacks_contents() :: [struct()]
  def twcc_feedbacks_contents() do
    [
      %Membrane.RTCP.TransportFeedbackPacket.TWCC{
        base_seq_num: 30_511,
        feedback_packet_count: 11,
        packet_status_count: 5,
        receive_deltas: [16_000_000, 22_000_000, -82_000_000, 0, 0],
        reference_time: 129_391_488_000_000
      },
      %Membrane.RTCP.TransportFeedbackPacket.TWCC{
        base_seq_num: 33_939,
        feedback_packet_count: 115,
        packet_status_count: 6,
        receive_deltas: [
          :not_received,
          :not_received,
          :not_received,
          :not_received,
          33_000_000,
          2_000_000
        ],
        reference_time: 129_396_864_000_000
      },
      %Membrane.RTCP.TransportFeedbackPacket.TWCC{
        base_seq_num: 2996,
        feedback_packet_count: 12,
        packet_status_count: 15,
        receive_deltas: [
          17_000_000,
          0,
          0,
          3_000_000,
          2_000_000,
          6_000_000,
          0,
          1_000_000,
          -1_000_000,
          13_000_000,
          7_000_000,
          1_000_000,
          7_000_000,
          0,
          4_000_000
        ],
        reference_time: 129_384_256_000_000
      },
      %Membrane.RTCP.TransportFeedbackPacket.TWCC{
        base_seq_num: 20_876,
        feedback_packet_count: 14,
        packet_status_count: 21,
        receive_deltas: [
          42_000_000,
          3_000_000,
          -4_000_000,
          1_000_000,
          4_000_000,
          0,
          4_000_000,
          3_000_000,
          0,
          0,
          0,
          0,
          2_000_000,
          -2_000_000,
          7_000_000,
          0,
          10_000_000,
          12_000_000,
          3_000_000,
          :not_received,
          1_000_000
        ],
        reference_time: 129_378_112_000_000
      }
    ]
  end

  # iso8601 does not allow nanoseconds
  @spec to_membrane_time(String.t(), non_neg_integer) :: Membrane.Time.t()
  def to_membrane_time(iso8601, nanoseconds) do
    Membrane.Time.from_iso8601!(iso8601) + Membrane.Time.nanoseconds(nanoseconds)
  end

  defp hex_to_bin(hex) do
    hex
    |> String.trim_trailing()
    |> String.upcase()
    |> Base.decode16()
    |> case do
      {:ok, packet} -> packet
    end
  end
end
