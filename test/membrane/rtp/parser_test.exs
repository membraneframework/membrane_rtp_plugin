defmodule Membrane.RTP.ParserTest do
  use ExUnit.Case

  alias Membrane.Buffer
  alias Membrane.RTP.{Fixtures, Parser}

  describe "Parser" do
    test "parse a packet" do
      state = %{}
      packet = Fixtures.sample_packet_binary()

      assert Parser.handle_process(:input, %Buffer{payload: packet}, nil, state) ==
               {{:ok,
                 buffer:
                   {:output,
                    %Membrane.Buffer{
                      metadata: %{
                        rtp: %{
                          sequence_number: 3983,
                          timestamp: 1_653_702_647,
                          payload_type: 14,
                          ssrc: 3_919_876_492,
                          csrcs: [],
                          extension: nil,
                          marker: false
                        }
                      },
                      payload: Fixtures.sample_packet_payload()
                    }}}, %{}}
    end
  end
end
