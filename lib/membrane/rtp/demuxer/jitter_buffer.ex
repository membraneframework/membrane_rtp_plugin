defmodule Membrane.RTP.Demuxer.JitterBuffer do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.{RTP, Time}
  alias Membrane.RTP.Demuxer
  alias Membrane.RTP.JitterBuffer.{BufferStore, Record}

  @max_timestamp Bitwise.bsl(1, 32) - 1

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            buffer_store: RTP.JitterBuffer.BufferStore.t(),
            ssrc: RTP.ssrc(),
            payload_type: RTP.payload_type(),
            pad: Membrane.Pad.ref() | nil,
            clock_rate: non_neg_integer() | nil,
            latency: Membrane.Time.t() | nil,
            initial_latency_waiting: boolean(),
            initialization_time: Membrane.Time.t(),
            max_latency_timer: reference() | nil,
            timestamp_base: Membrane.Time.t(),
            previous_timestamp: Membrane.Time.t()
          }

    @enforce_keys [
      :ssrc,
      :payload_type,
      :initial_latency_waiting,
      :initialization_time,
      :timestamp_base,
      :previous_timestamp
    ]

    defstruct @enforce_keys ++
                [
                  buffer_store: %RTP.JitterBuffer.BufferStore{},
                  pad: nil,
                  clock_rate: nil,
                  latency: nil,
                  max_latency_timer: nil
                ]
  end

  @spec new(ExRTP.Packet.t()) :: State.t()
  def new(packet) do
    %State{
      ssrc: packet.ssrc,
      payload_type: packet.payload_type,
      initial_latency_waiting: true,
      initialization_time: Membrane.Time.monotonic_time(),
      timestamp_base: packet.timestamp,
      previous_timestamp: packet.timestamp
    }
  end

  @spec initialize(
          State.t(),
          Membrane.Pad.ref(),
          Demuxer.output_pad_options(),
          RTP.PayloadFormat.payload_type_mapping()
        ) :: State.t()
  def initialize(jitter_buffer_state, pad, pad_options, payload_type_mapping) do
    %{clock_rate: clock_rate} =
      RTP.PayloadFormat.resolve(
        payload_type: jitter_buffer_state.payload_type,
        clock_rate: pad_options.clock_rate,
        payload_type_mapping: payload_type_mapping
      )

    time_since_initialization =
      Time.monotonic_time() - jitter_buffer_state.initialization_time

    initial_latency_left = pad_options.jitter_buffer_latency - time_since_initialization

    if initial_latency_left > 0 do
      Process.send_after(
        self(),
        {:initial_latency_passed, jitter_buffer_state.ssrc},
        Membrane.Time.as_milliseconds(initial_latency_left, :round)
      )
    end

    %State{
      jitter_buffer_state
      | pad: pad,
        clock_rate: clock_rate,
        latency: pad_options.jitter_buffer_latency,
        initial_latency_waiting: initial_latency_left > 0
    }
  end

  @spec latency_timer_expired(State.t()) :: State.t()
  def latency_timer_expired(jitter_buffer_state) do
    %State{jitter_buffer_state | max_latency_timer: nil}
  end

  @spec initial_latency_passed(State.t()) :: State.t()
  def initial_latency_passed(jitter_buffer_state) do
    %State{jitter_buffer_state | initial_latency_waiting: false}
  end

  @spec insert_buffer(State.t(), Membrane.Buffer.t()) :: State.t()
  def insert_buffer(jitter_buffer_state, buffer) do
    case BufferStore.insert_buffer(jitter_buffer_state.buffer_store, buffer) do
      {:ok, buffer_store} ->
        %State{jitter_buffer_state | buffer_store: buffer_store}

      {:error, :late_packet} ->
        Membrane.Logger.debug("Late packet has arrived")
        jitter_buffer_state
    end
  end

  @spec get_output_actions(State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  def get_output_actions(jitter_buffer_state) do
    if jitter_buffer_state.initial_latency_waiting do
      {[], jitter_buffer_state}
    else
      {too_old_records, buffer_store} =
        BufferStore.flush_older_than(
          jitter_buffer_state.buffer_store,
          jitter_buffer_state.latency
        )

      {buffers, buffer_store} = BufferStore.flush_ordered(buffer_store)
      jitter_buffer_state = %State{jitter_buffer_state | buffer_store: buffer_store}

      {actions, jitter_buffer_state} =
        (too_old_records ++ buffers)
        |> Enum.flat_map_reduce(jitter_buffer_state, &record_to_action/2)

      jitter_buffer_state = set_timer(jitter_buffer_state)

      {actions, jitter_buffer_state}
    end
  end

  @spec get_end_of_stream_actions(State.t()) :: [Membrane.Element.Action.t()]
  def get_end_of_stream_actions(jitter_buffer_state) do
    if jitter_buffer_state.pad == nil do
      []
    else
      {actions, _jitter_buffer_state} =
        jitter_buffer_state.buffer_store
        |> BufferStore.dump()
        |> Enum.flat_map_reduce(jitter_buffer_state, &record_to_action/2)

      actions ++ [end_of_stream: jitter_buffer_state.pad]
    end
  end

  @spec set_timer(State.t()) :: State.t()
  defp set_timer(%State{max_latency_timer: nil, latency: latency} = jitter_buffer_state)
       when latency > 0 do
    new_timer =
      case BufferStore.first_record_timestamp(jitter_buffer_state.buffer_store) do
        nil ->
          nil

        buffer_ts ->
          since_insertion = Time.monotonic_time() - buffer_ts
          send_after_time = Time.as_milliseconds(latency - since_insertion, :round)

          if send_after_time > 0 do
            Process.send_after(
              self(),
              {:latency_timer_expired, jitter_buffer_state.ssrc},
              send_after_time
            )
          else
            nil
          end
      end

    %State{jitter_buffer_state | max_latency_timer: new_timer}
  end

  defp set_timer(jitter_buffer_state) do
    jitter_buffer_state
  end

  @spec record_to_action(Record.t() | nil, State.t()) ::
          {[Membrane.Event.Discontinuity.t() | Membrane.Buffer.t()], State.t()}
  defp record_to_action(nil, jitter_buffer_state) do
    {[event: {jitter_buffer_state.pad, %Membrane.Event.Discontinuity{}}], jitter_buffer_state}
  end

  defp record_to_action(record, jitter_buffer_state) do
    rtp_timestamp = record.buffer.metadata.rtp.timestamp

    # timestamps in RTP don't have to be monotonic therefore there can be
    # a situation where in 2 consecutive packets the latter packet will have smaller timestamp
    # than the previous one while not overflowing the timestamp number
    # https://datatracker.ietf.org/doc/html/rfc3550#section-5.1

    timestamp_base =
      case RTP.Utils.from_which_rollover(
             jitter_buffer_state.previous_timestamp,
             rtp_timestamp,
             @max_timestamp
           ) do
        :next -> jitter_buffer_state.timestamp_base - @max_timestamp
        :previous -> jitter_buffer_state.timestamp_base + @max_timestamp
        :current -> jitter_buffer_state.timestamp_base
      end

    timestamp = div(Time.seconds(rtp_timestamp - timestamp_base), jitter_buffer_state.clock_rate)
    buffer = %Membrane.Buffer{record.buffer | pts: timestamp}
    actions = if buffer.payload == <<>>, do: [], else: [buffer: {jitter_buffer_state.pad, buffer}]

    jitter_buffer_state = %State{
      jitter_buffer_state
      | timestamp_base: timestamp_base,
        previous_timestamp: rtp_timestamp
    }

    {actions, jitter_buffer_state}
  end
end
