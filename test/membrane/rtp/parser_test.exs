defmodule Membrane.RTP.ParserTest do
  use ExUnit.Case

  alias Membrane.Buffer
  alias Membrane.RTP.{Parser, SamplePacket}

  describe "Parser" do
    test "sends caps and buffer action when parsing first packet" do
      state = %Parser.State{}
      packet = SamplePacket.sample_packet()

      assert Parser.handle_process(:input, %Buffer{payload: packet}, nil, state) ==
               {{:ok,
                 [
                   caps: {:output, %Membrane.RTP{payload_type: :mpa, raw_payload_type: 14}},
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
                        payload: SamplePacket.sample_packet_payload()
                      }}
                 ]}, %Parser.State{raw_payload_type: 14}}
    end

    test "sends buffer action with payload on non-first packet" do
      state = %Parser.State{raw_payload_type: 14}
      packet = SamplePacket.sample_packet()

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
                        payload: SamplePacket.sample_packet_payload()
                      }}
                 ]}, %Parser.State{raw_payload_type: 14}}
    end
  end
end
