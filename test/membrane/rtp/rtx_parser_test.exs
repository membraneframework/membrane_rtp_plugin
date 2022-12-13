defmodule Membrane.RTP.RTXParserTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.Header.Extension
  alias Membrane.RTP.RTXParser

  defp init_state(opts \\ []) do
    [original_payload_type: 96]
    |> Keyword.merge(opts)
    |> then(&struct!(RTXParser, &1))
    |> RTXParser.handle_init()
    |> then(&elem(&1, 1))
  end

  describe "handle_process/4" do
    test "RTX buffer" do
      state = init_state()

      original_seq_num = 22_406

      packet = %Buffer{
        payload: <<original_seq_num::16, 1, 2, 3, 4>>,
        pts: nil,
        dts: nil,
        metadata: %{
          rtp: %{
            csrcs: [],
            extensions: [],
            marker: true,
            padding_size: 0,
            payload_type: 97,
            sequence_number: 12_923,
            ssrc: 1_504_003_399,
            timestamp: 3_876_519_202,
            total_header_size: 24
          }
        }
      }

      assert {{:ok, actions}, ^state} = RTXParser.handle_process(:input, packet, %{}, state)
      assert {:output, buffer} = Keyword.fetch!(actions, :buffer)
      assert buffer.payload == <<1, 2, 3, 4>>
      assert meta = buffer.metadata.rtp

      for key <- [
            :csrcs,
            :extensions,
            :marker,
            :padding_size,
            :ssrc,
            :timestamp,
            :total_header_size
          ] do
        assert meta[key] == packet.metadata.rtp[key]
      end

      assert meta.payload_type == 96
      assert meta.sequence_number == original_seq_num
    end

    test "ignore padding packet" do
      state = init_state()

      padding_packet = %Buffer{
        payload: "",
        metadata: %{
          rtp: %{
            csrcs: [],
            extensions: [],
            marker: false,
            padding_size: 224,
            payload_type: 97,
            sequence_number: 22_802,
            ssrc: 2_176_609_592,
            timestamp: 2_336_745_526,
            total_header_size: 20
          }
        }
      }

      assert RTXParser.handle_process(:input, padding_packet, %{}, state) == {:ok, state}
    end

    test "rewrite rid extension" do
      state = init_state(rid_id: 10, repaired_rid_id: 11)

      packet = %Buffer{
        payload: <<87, 134, 1, 2, 3, 4>>,
        pts: nil,
        dts: nil,
        metadata: %{
          rtp: %{
            csrcs: [],
            extensions: [
              %Extension{identifier: 9, data: <<48>>},
              %Extension{identifier: 11, data: "l"}
            ],
            marker: true,
            padding_size: 0,
            payload_type: 97,
            sequence_number: 12_923,
            ssrc: 1_504_003_399,
            timestamp: 3_876_519_202,
            total_header_size: 24
          }
        }
      }

      assert {{:ok, actions}, ^state} = RTXParser.handle_process(:input, packet, %{}, state)
      assert {:output, buffer} = Keyword.fetch!(actions, :buffer)
      assert %Extension{identifier: 9, data: <<48>>} in buffer.metadata.rtp.extensions
      assert %Extension{identifier: 10, data: "l"} in buffer.metadata.rtp.extensions
    end
  end
end
