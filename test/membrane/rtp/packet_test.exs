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

  test "generates padding" do
    ref_packet = Fixtures.sample_packet_binary_with_padding()
    test_packet = Fixtures.sample_packet()
    assert ref_packet == Packet.serialize(test_packet, padding_size: 20)
  end

  test "ignores padding" do
    ref_packet = Fixtures.sample_packet()
    test_packet = Fixtures.sample_packet_binary_with_padding()

    assert {:ok, %{packet: ^ref_packet, padding_size: 20}} =
             Packet.parse(test_packet, @encrypted?)
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
end
