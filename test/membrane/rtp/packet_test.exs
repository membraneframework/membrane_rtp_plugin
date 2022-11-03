defmodule Membrane.RTP.PacketTest do
  use ExUnit.Case

  alias Membrane.RTP.{Fixtures, Header, Packet}

  @encrypted? false

  test "parses and serializes valid packets" do
    packet = Fixtures.sample_packet()

    assert {:ok, %{packet: ^packet}} = Packet.parse(Fixtures.sample_packet_binary(), @encrypted?)

    assert Packet.serialize(Fixtures.sample_packet()) == Fixtures.sample_packet_binary()
  end

  test "returns error when version is not supported" do
    assert Packet.parse(<<1::2, 1233::1022>>, @encrypted?) == {:error, :wrong_version}
  end

  test "returns error when packet is too short" do
    assert Packet.parse(<<128, 127, 0, 0, 1>>, @encrypted?) == {:error, :malformed_packet}
  end

  test "parses and serializes csrcs correctly" do
    <<header_1::4, _old_cc::4, header_2::88, payload::binary>> = Fixtures.sample_packet_binary()
    packet_binary = <<header_1::4, 2::4, header_2::88, 12::32, 21::32, payload::binary>>

    packet = %Packet{
      Fixtures.sample_packet()
      | header: %Header{Fixtures.sample_header() | csrcs: [12, 21]}
    }

    assert {:ok, %{packet: ^packet}} = Packet.parse(packet_binary, @encrypted?)
    assert Packet.serialize(packet) == packet_binary
  end

  test "ignores padding" do
    test_padding_size = 2
    padding_octets = test_padding_size - 1
    test_padding = <<0::size(padding_octets)-unit(8), test_padding_size>>
    <<version::2, _padding::1, rest::bitstring>> = Fixtures.sample_packet_binary()
    test_packet = <<version::2, 1::1, rest::bitstring, test_padding::binary>>

    sample_packet = Fixtures.sample_packet()

    assert {:ok, %{packet: ^sample_packet}} = Packet.parse(test_packet, @encrypted?)

    assert Packet.serialize(Fixtures.sample_packet(), align_to: 4) == test_packet
  end

  test "reads and serializes extension header" do
    extension_header = <<0xBE, 0xDE, 1::16, 1::4, 0::4, 0xBE, 0::16>>

    expected_parsed_extensions = [
      %Membrane.RTP.Header.Extension{data: <<0xBE>>, identifier: 1}
    ]

    # Extension is stored on 4th bit of header
    <<header_1::3, _extension::1, header_2::92, payload::binary>> =
      Fixtures.sample_packet_binary()

    # Glueing data back together with extension header in place
    packet_binary = <<header_1::3, 1::1, header_2::92, extension_header::binary, payload::binary>>

    packet = %Packet{
      Fixtures.sample_packet()
      | header: %Header{Fixtures.sample_header() | extensions: expected_parsed_extensions}
    }

    assert {:ok, %{packet: ^packet}} = Packet.parse(packet_binary, @encrypted?)
    assert Packet.serialize(packet) == packet_binary
  end

  test "Serialize and then parse return same packet" do
    packet = %Packet{
      Fixtures.sample_packet()
      | header: %Header{
          Fixtures.sample_header()
          | extensions: [
              %Membrane.RTP.Header.Extension{data: <<0xBE, 0>>, identifier: 1},
              %Membrane.RTP.Header.Extension{data: <<0xDE, 0>>, identifier: 2}
            ]
        }
    }

    serialized = Packet.serialize(packet)

    {:ok, %{packet: parsed}} = Packet.parse(serialized, @encrypted?)

    assert ^packet = parsed
    assert Packet.serialize(parsed) == serialized
  end

  test "builds correct padding packet" do
    packet = %Packet{
      payload: <<>>,
      header: Fixtures.sample_header()
    }

    serialized = Packet.serialize(packet, is_padding_packet?: true)

    assert {:ok, %{has_padding?: true, packet: %Packet{payload: <<>>}}} =
             Packet.parse(serialized, false)

    # expected size of the padding packet - the size of the header
    expected_padding_size = 255
    expected_zeros = expected_padding_size - 1

    assert <<_header::binary-size(12), 0::integer-size(expected_zeros)-unit(8),
             ^expected_padding_size::8>> = serialized
  end

  test "correctly aligns padding packet" do
    packet = %Packet{
      payload: <<>>,
      header: Fixtures.sample_header()
    }

    serialized = Packet.serialize(packet, is_padding_packet?: true, align_to: 16)
    assert byte_size(serialized) == 256
  end

  test "refuses to build a padding packet with non-empty payload" do
    packet = Fixtures.sample_packet()

    assert_raise RuntimeError, fn ->
      Packet.serialize(packet, is_padding_packet?: true)
    end
  end
end
