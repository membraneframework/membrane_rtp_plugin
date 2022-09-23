defmodule Membrane.RTP.Serializer do
  @moduledoc """
  Given following RTP payloads and their minimal metadata, creates their proper header information,
  incrementing timestamps and sequence numbers for each packet. Header information then is put
  inside buffer's metadata under `:rtp` key.

  Accepts the following metadata under `:rtp` key: `:marker`, `:csrcs`, `:extensions`.
  See `Membrane.RTP.Header` for their meaning and specifications.
  """
  use Membrane.Filter

  require Bitwise
  alias Membrane.{RemoteStream, RTP}

  @max_seq_num Bitwise.bsl(1, 16) - 1
  @max_timestamp Bitwise.bsl(1, 32) - 1

  def_input_pad :input, caps: RTP, demand_mode: :auto

  def_output_pad :output,
    caps: {RemoteStream, type: :packetized, content_format: RTP},
    demand_mode: :auto

  def_options ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              alignment: [
                default: 1,
                spec: pos_integer(),
                description: """
                Number of bytes that each packet should be aligned to.
                Alignment is achieved by adding RTP padding.
                """
              ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    defstruct [
      :ssrc,
      :payload_type,
      :clock_rate,
      :alignment,
      sequence_number: 0,
      init_timestamp: 0
    ]

    @type t :: %__MODULE__{
            ssrc: RTP.ssrc_t(),
            payload_type: RTP.payload_type_t(),
            clock_rate: RTP.clock_rate_t(),
            alignment: pos_integer(),
            sequence_number: non_neg_integer(),
            init_timestamp: non_neg_integer()
          }
  end

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        sequence_number: Enum.random(0..@max_seq_num),
        init_timestamp: Enum.random(0..@max_timestamp)
      })

    {:ok, struct!(State, state)}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    caps = %RemoteStream{type: :packetized, content_format: RTP}
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {rtp_metadata, metadata} = Map.pop(buffer.metadata, :rtp, %{})

    rtp_offset =
      buffer.pts
      |> Ratio.mult(state.clock_rate)
      |> Membrane.Time.to_seconds()

    rtp_timestamp = rem(state.init_timestamp + rtp_offset, @max_timestamp + 1)

    state = Map.update!(state, :sequence_number, &rem(&1 + 1, @max_seq_num + 1))

    header = %{
      ssrc: state.ssrc,
      marker: Map.get(rtp_metadata, :marker, false),
      payload_type: state.payload_type,
      timestamp: rtp_timestamp,
      sequence_number: state.sequence_number,
      csrcs: Map.get(rtp_metadata, :csrcs, []),
      extensions: Map.get(rtp_metadata, :extensions, [])
    }

    buffer = %Membrane.Buffer{
      buffer
      | metadata: Map.put(metadata, :rtp, header),
        payload: buffer.payload
    }

    {{:ok, buffer: {:output, buffer}}, state}
  end
end
