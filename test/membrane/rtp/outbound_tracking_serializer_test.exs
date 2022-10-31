defmodule Membrane.RTP.OutboundTrackingSerializerTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.{OutboundTrackingSerializer, Packet}

  test "generates padding packets" do
    serializer_state = %OutboundTrackingSerializer.State{}

    buffer = %Buffer{
      metadata: %{
        rtp: %{
          is_padding?: true,
          ssrc: 1,
          payload_type: 0,
          marker: true,
          extensions: [],
          csrcs: [],
          timestamp: 0,
          sequence_number: 0
        }
      },
      payload: <<>>
    }

    assert {{:ok, buffer: {:output, %Buffer{payload: payload}}}, _state} =
             OutboundTrackingSerializer.handle_process(:input, buffer, nil, serializer_state)

    assert byte_size(payload) == 255

    assert {:ok, %{has_padding?: true, packet: %Packet{payload: <<>>}}} =
             Packet.parse(payload, false)

    # expected size of the padding packet - the size of the header
    expected_padding_size = 255 - 12
    expected_zeros = expected_padding_size - 1

    assert <<_header::binary-size(12), 0::integer-size(expected_zeros)-unit(8),
             ^expected_padding_size::8>> = payload
  end
end
