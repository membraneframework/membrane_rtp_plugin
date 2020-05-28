defmodule Membrane.RTP.ParserTest do
  use ExUnit.Case

  alias Membrane.Buffer
  alias Membrane.RTP.{Fixtures, Parser}

  describe "Parser" do
    test "sends caps and buffer action when parsing first packet" do
      state = %Parser.State{}
      packet = Fixtures.sample_packet()

      assert Parser.handle_process(:input, %Buffer{payload: packet}, nil, state) ==
               {{:ok,
                 [
                   caps: {:output, %Membrane.RTP{payload_type: 14}},
                   buffer:
                     {:output,
                      %Membrane.Buffer{
                        metadata: %{
                          rtp: %{
                            sequence_number: 3983,
                            timestamp: 1_653_702_647,
                            payload_type: 14,
                            ssrc: 3_919_876_492
                          }
                        },
                        payload: Fixtures.sample_packet_payload()
                      }}
                 ]}, %Parser.State{payload_type: 14}}
    end

    test "sends buffer action with payload on non-first packet" do
      state = %Parser.State{payload_type: 14}
      packet = Fixtures.sample_packet()

      assert Parser.handle_process(:input, %Buffer{payload: packet}, nil, state) ==
               {{:ok,
                 [
                   buffer:
                     {:output,
                      %Membrane.Buffer{
                        metadata: %{
                          rtp: %{
                            sequence_number: 3983,
                            timestamp: 1_653_702_647,
                            payload_type: 14,
                            ssrc: 3_919_876_492
                          }
                        },
                        payload: Fixtures.sample_packet_payload()
                      }}
                 ]}, %Parser.State{payload_type: 14}}
    end
  end
end
