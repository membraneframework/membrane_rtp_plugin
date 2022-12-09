defmodule Membrane.RTP.RTXParser do
  @moduledoc """
  An element responsible for handling retransmission packets (`rtx`) defined in
  [RFC 4588](https://datatracker.ietf.org/doc/html/rfc4588#section-4).

  It parses RTX packet and recreates the lost packet
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, RTP}

  def_input_pad :input, caps: RTP, demand_mode: :auto
  def_output_pad :output, caps: RTP, demand_mode: :auto

  def_options rtx_payload_type: [
                description: "Payload type of retransmission RTP stream"
              ],
              payload_type: [
                description:
                  "Payload type of original RTP stream that is retransmitted via this SSRC"
              ],
              repaired_rid_id: [
                spec: RTP.Header.Extension.identifier_t(),
                description:
                  "The numerical ID of an extension carrying repaired-rid that will be rewritten into rid",
                default: nil
              ],
              rid_id: [
                spec: RTP.Header.Extension.identifier_t(),
                description:
                  "The numerical ID of an extension carrying rid, will replace repaired_rid_id",
                default: nil
              ]

  @impl true
  def handle_init(opts) do
    {:ok, Map.from_struct(opts)}
  end

  @impl true
  def handle_caps(:input, rtp_caps, _ctx, state) do
    {{:ok, forward: rtp_caps}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload} = buffer, _ctx, state)
      when byte_size(payload) >= 2 do
    <<original_seq_num::16, original_payload::binary>> = payload

    Membrane.Logger.debug(
      "[RTX SSRC: #{buffer.metadata.rtp.ssrc}] got retransmitted packet with seq_num #{original_seq_num}"
    )

    extensions =
      buffer.metadata.rtp.extensions
      |> maybe_rewrite_rid_ext_id(state)

    recreated_buffer = %Buffer{
      buffer
      | payload: original_payload,
        metadata: %{
          rtp: %{
            buffer.metadata.rtp
            | extensions: extensions,
              sequence_number: original_seq_num,
              payload_type: state.payload_type
          }
        }
    }

    {{:ok, buffer: {:output, recreated_buffer}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    # Ignore empty buffers, most likely used for bandwidth estimation
    if byte_size(payload) > 0 do
      Membrane.Logger.warn(
        "Received invalid RTX buffer with sequence_number #{metadata.rtp.sequence_number}"
      )
    end

    {:ok, state}
  end

  defp maybe_rewrite_rid_ext_id(extensions, %{repaired_rid_id: rrid, rid_id: rid})
       when rrid != nil and rid != nil do
    extensions
    |> Enum.map(fn
      %{identifier: ^rrid} = ext -> %{ext | identifier: rid}
      ext -> ext
    end)
  end

  defp maybe_rewrite_rid_ext_id(extensions, _state) do
    extensions
  end
end
