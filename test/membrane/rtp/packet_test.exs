defmodule Membrane.RTP.PacketTest do
  use ExUnit.Case

  alias Membrane.RTP.{Header, Packet, Fixtures}

  @parse_payload true

  test "parses and serializes valid packets" do
    assert Packet.parse(Fixtures.sample_packet_binary(), @parse_payload) ==
             {:ok, Fixtures.sample_packet()}

    assert Packet.serialize(Fixtures.sample_packet()) == Fixtures.sample_packet_binary()
  end

  test "returns error when version is not supported" do
    assert Packet.parse(<<1::2, 1233::1022>>, @parse_payload) == {:error, :wrong_version}
  end

  test "returns error when packet is too short" do
    assert Packet.parse(<<128, 127, 0, 0, 1>>, @parse_payload) == {:error, :malformed_packet}
  end

  test "parses and serializes csrcs correctly" do
    <<header_1::4, _old_cc::4, header_2::88, payload::binary()>> = Fixtures.sample_packet_binary()
    packet_binary = <<header_1::4, 2::4, header_2::88, 12::32, 21::32, payload::binary()>>

    packet = %Packet{
      Fixtures.sample_packet()
      | header: %Header{Fixtures.sample_header() | csrcs: [12, 21], total_header_size: 160}
    }

    assert Packet.parse(packet_binary, @parse_payload) == {:ok, packet}
    assert Packet.serialize(packet) == packet_binary
  end

  test "ignores padding" do
    test_padding_size = 2
    padding_octets = test_padding_size - 1
    test_padding = <<0::size(padding_octets)-unit(8), test_padding_size>>
    <<version::2, _padding::1, rest::bitstring>> = Fixtures.sample_packet_binary()
    test_packet = <<version::2, 1::1, rest::bitstring, test_padding::binary>>

    sample_packet = Fixtures.sample_packet()

    assert Packet.parse(test_packet, @parse_payload) ==
             {:ok, %{sample_packet | header: %{sample_packet.header | has_padding?: true}}}

    assert Packet.serialize(Fixtures.sample_packet(), align_to: 4) == test_packet
  end

  test "reads and serializes extension header" do
    extension_header = <<0::16, 4::16, 1::32, 2::32, 3::32, 4::32>>

    expected_parsed_extension = %Header.Extension{
      data: <<1::32, 2::32, 3::32, 4::32>>,
      profile_specific: <<0, 0>>
    }

    # Extension is stored on 4th bit of header
    <<header_1::3, _extension::1, header_2::92, payload::binary>> =
      Fixtures.sample_packet_binary()

    # Glueing data back together with extension header in place
    packet_binary = <<header_1::3, 1::1, header_2::92, extension_header::binary, payload::binary>>

    packet = %Packet{
      Fixtures.sample_packet()
      | header: %Header{
          Fixtures.sample_header()
          | extension: expected_parsed_extension,
            total_header_size: 256
        }
    }

    assert Packet.parse(packet_binary, @parse_payload) == {:ok, packet}
    assert Packet.serialize(packet) == packet_binary
  end
end
