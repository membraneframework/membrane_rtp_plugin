defmodule Membrane.RTP.OutboundTrackingSerializerTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.OutboundTrackingSerializer

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

    assert byte_size(payload) == 256
  end
end
