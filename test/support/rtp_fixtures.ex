defmodule Membrane.RTP.Fixtures do
  @moduledoc false
  alias Membrane.RTP.{Header, Packet}

  @external_resource "test/fixtures/rtp/rtp_packet.bin"
  @sample_packet File.read!("test/fixtures/rtp/rtp_packet.bin")
  @external_resource "test/fixtures/rtp/rtp_packet_payload.bin"
  @sample_packet_payload File.read!("test/fixtures/rtp/rtp_packet_payload.bin")

  @spec sample_packet() :: binary()
  def sample_packet_binary, do: @sample_packet

  @spec sample_packet() :: Packet.t()
  def sample_packet, do: %Packet{header: sample_header(), payload: sample_packet_payload()}

  @spec sample_packet_payload() :: binary()
  def sample_packet_payload, do: @sample_packet_payload

  @spec sample_buffer() :: Membrane.Buffer.t()
  def sample_buffer,
    do: %Membrane.Buffer{
      payload: sample_packet_payload(),
      metadata: %{
        rtp_header: sample_header()
      }
    }

  def sample_header,
    do: %Header{
      payload_type: 14,
      sequence_number: 3983,
      ssrc: 3_919_876_492,
      timestamp: 1_653_702_647,
      total_header_size: 96
    }

  @spec fake_packet_list(Range.t()) :: [binary()]
  def fake_packet_list(range) do
    base_seqnumber = 65_403
    base_timestamp = 383_400
    ssrc = 562_678_578_632

    Enum.map(range, fn packet_number ->
      <<2::2, 0::1, 0::1, 0::4, 0::1, 14::7, base_seqnumber + packet_number::16,
        base_timestamp + 30_000 * packet_number::32, ssrc::32, sample_packet_payload()::binary()>>
    end)
  end
end
