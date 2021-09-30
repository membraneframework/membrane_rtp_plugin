defmodule Membrane.RTP.Serializer do
  @moduledoc """
  Given following RTP payloads and their minimal metadata, creates their proper header information,
  incrementing timestamps and sequence numbers for each packet. Header information then is put
  inside buffer's metadata under `:rtp` key.

  Accepts the following metadata under `:rtp` key: `:marker`, `:csrcs`, `:extension`.
  See `Membrane.RTP.Header` for their meaning and specifications.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, RemoteStream}

  @max_seq_num 65_535
  @max_timestamp 0xFFFFFFFF

  def_input_pad :input, caps: RTP, demand_unit: :buffers
  def_output_pad :output, caps: {RemoteStream, type: :packetized, content_format: RTP}

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
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    {rtp_metadata, metadata} = Map.pop(metadata, :rtp, %{})

    rtp_offset =
      metadata.timestamp
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
      extensions: [Map.get(rtp_metadata, :extension)]
    }

    buffer = %Membrane.Buffer{
      metadata: Map.put(metadata, :rtp, header),
      payload: payload
    }

    {{:ok, buffer: {:output, buffer}}, state}
  end
end
